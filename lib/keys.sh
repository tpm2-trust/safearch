# Signing keys for a build: Secure Boot and expected-PCR signing. Sourced by
# build.sh; expects die() and log(), runs as root.
#
#   keys_load SUMMARY_JSON   which keys this build uses (`mkosi --json summary`)
#   keys_mkosi_args          mkosi options that point the signing at those keys
#   keys_export OUT_DIR      public Secure Boot material for safespace seal
#   keys_ensure_pcr          create the PCR signing keys on the first build:
#                            mkosi's (all boot phases) and the identity key
#                            (enter-initrd only, lib/compose.sh)
#
# Where the Secure Boot keys come from: an sbctl key set (PK, KEK, db in
# <keydir>/<K>/<K>.{key,pem}, plus the GUID file).
#   - default: the host's sbctl, /var/lib/sbctl (SecureBootKey= in mkosi.conf)
#   - dedicated: SAFESPACE_SBCTL_CONFIG=<sbctl.conf> (Environment= in
#     mkosi.local.conf), an sbctl configuration of its own with its own keydir
#     and guid, created with `sbctl --config <it> create-keys`. build.sh then
#     signs with that set's db key (keys_mkosi_args).
# Only file keys are supported: the .auth updates are signed with efitools
# from the PK/KEK key files. (sbctl's own `enroll-keys --export auth` cannot
# replace that: its --append export is signed for replacement, not for
# APPEND_WRITE, so safespace seal's default mode would be refused.) Keys on a
# YubiKey (sbctl --*-keytype yubikey) are refused with a pointer to README.md,
# "Secure Boot keys".
#
# Only public material goes into the image: certificates, the signed .auth
# updates and the GUID. mkosi.postoutput refuses an image tree that holds
# anything else, and a UKI not signed by the exported db.pem.

KEYS_SB_DIR="" KEYS_GUID="" KEYS_SB_CERT="" KEYS_PCR_KEY="" KEYS_PCR_CERT="" KEYS_DEDICATED=0
KEYS_ID_KEY="" KEYS_ID_CERT=""

# The value of a top-level "key: value" line of an sbctl configuration (YAML).
keys_sbctl_conf() { # FILE KEY
	sed -n "s/^$2:[[:space:]]*//p" "$1" | head -1 | sed "s/^[\"']//; s/[\"']\$//"
}

keys_load() {
	local summary=$1 sb sb_key conf
	{ read -r sb; read -r sb_key; read -r KEYS_SB_CERT; read -r KEYS_PCR_KEY; read -r KEYS_PCR_CERT; read -r conf; } < <(
		python3 -I -c '
import json, sys
c = json.load(sys.stdin)["Images"][-1]
for k in ("SecureBoot", "SecureBootKey", "SecureBootCertificate", "SignExpectedPcrKey", "SignExpectedPcrCertificate"):
    v = c.get(k)
    print("" if v is None else v)
print((c.get("Environment") or {}).get("SAFESPACE_SBCTL_CONFIG", ""))
' <"$summary") || die "cannot read the key settings from mkosi summary"
	[[ $sb == True ]] || die "SecureBoot= is off: safespace images are always signed"
	[[ -n $KEYS_PCR_KEY && -n $KEYS_PCR_CERT ]] || die "SignExpectedPcrKey=/SignExpectedPcrCertificate= not set (mkosi.conf)"
	KEYS_ID_KEY=$(dirname "$KEYS_PCR_KEY")/identity.key
	KEYS_ID_CERT=$(dirname "$KEYS_PCR_CERT")/identity.crt
	if [[ -n $conf ]]; then
		[[ -f $conf ]] || die "SAFESPACE_SBCTL_CONFIG=$conf does not exist (create it, see README.md, \"Secure Boot keys\")"
		KEYS_SB_DIR=$(keys_sbctl_conf "$conf" keydir)
		KEYS_GUID=$(keys_sbctl_conf "$conf" guid)
		[[ -n $KEYS_SB_DIR && -n $KEYS_GUID ]] || die "$conf: needs keydir: and guid:"
		KEYS_SB_CERT=$KEYS_SB_DIR/db/db.pem
		KEYS_DEDICATED=1
	else
		# The host's sbctl: SecureBootKey= names its db key.
		[[ $sb_key == */keys/db/db.key ]] ||
			die "SecureBootKey=$sb_key is not in sbctl's layout (<dir>/keys/db/db.key): use a dedicated sbctl key set instead (SAFESPACE_SBCTL_CONFIG, README.md \"Secure Boot keys\")"
		KEYS_SB_DIR=${sb_key%/db/db.key}
		KEYS_GUID=${sb_key%/keys/db/db.key}/GUID
	fi
	local k
	for k in PK KEK db; do
		[[ -r $KEYS_SB_DIR/$k/$k.key && -r $KEYS_SB_DIR/$k/$k.pem ]] ||
			die "cannot read $KEYS_SB_DIR/$k/$k.{key,pem} (run as root; keys created?)"
		grep -q 'PRIVATE KEY' "$KEYS_SB_DIR/$k/$k.key" ||
			die "$KEYS_SB_DIR/$k/$k.key is not a private key file (a YubiKey key?): not supported yet, see README.md \"Secure Boot keys\""
	done
	[[ -r $KEYS_GUID ]] || die "no GUID file $KEYS_GUID"
}

# Sign with the dedicated key set's db key instead of mkosi.conf's.
keys_mkosi_args() {
	((KEYS_DEDICATED)) || return 0
	echo "--secure-boot-key=$KEYS_SB_DIR/db/db.key"
	echo "--secure-boot-certificate=$KEYS_SB_DIR/db/db.pem"
}

keys_fingerprint() { openssl x509 -in "$1" -noout -fingerprint -sha256 | cut -d= -f2; }

# Every signed build ships the public half of the keys it is signed with, so
# safespace seal can enroll them on a machine in Setup Mode. Written anew on
# every build, so the image can never carry the keys of another key set.
#   PK.pem KEK.pem db.pem          certificates
#   PK.auth KEK.auth db.auth       signed updates that replace the variable
#   KEK-append.auth db-append.auth signed updates that add to the variable
#   GUID                           signature owner
# PK signs PK and KEK, KEK signs db, as the UEFI spec requires.
keys_export() { # OUT_DIR
	local out=$1 tmp ts k guid
	guid=$(tr -d '[:space:]' <"$KEYS_GUID")
	tmp=$(mktemp -d)
	# One timestamp for all updates; firmware rejects updates older than the
	# variable's current one, so a fresh export also replaces older enrollments.
	ts=$(date -u '+%F %T')
	for k in PK KEK db; do
		openssl x509 -in "$KEYS_SB_DIR/$k/$k.pem" -out "$tmp/$k.pem" || { rm -rf "$tmp"; die "$k.pem is not a certificate"; }
		cert-to-efi-sig-list -g "$guid" "$tmp/$k.pem" "$tmp/$k.esl" >/dev/null
	done
	sign() { # signer var esl out [-a]
		sign-efi-sig-list ${5:-} -t "$ts" -k "$KEYS_SB_DIR/$1/$1.key" -c "$KEYS_SB_DIR/$1/$1.pem" "$2" "$3" "$4" >/dev/null
	}
	sign PK PK "$tmp/PK.esl" "$tmp/PK.auth" &&
		sign PK KEK "$tmp/KEK.esl" "$tmp/KEK.auth" &&
		sign PK KEK "$tmp/KEK.esl" "$tmp/KEK-append.auth" -a &&
		sign KEK db "$tmp/db.esl" "$tmp/db.auth" &&
		sign KEK db "$tmp/db.esl" "$tmp/db-append.auth" -a || { rm -rf "$tmp"; die "sign-efi-sig-list failed"; }
	echo "$guid" >"$tmp/GUID"
	rm -rf "$out"
	mkdir -p "$out"
	cp "$tmp"/{PK,KEK,db}.pem "$tmp"/*.auth "$tmp/GUID" "$out/"
	rm -rf "$tmp"
	chmod 0644 "$out"/*
	[[ $(keys_fingerprint "$out/db.pem") == "$(keys_fingerprint "$KEYS_SB_CERT")" ]] ||
		die "the exported db.pem ($KEYS_SB_DIR) is not the signing certificate $KEYS_SB_CERT"
	for k in PK KEK db; do
		log "  $k: $(openssl x509 -in "$out/$k.pem" -noout -subject -nameopt oneline | sed 's/^subject=//'), valid until $(openssl x509 -in "$out/$k.pem" -noout -enddate | cut -d= -f2)"
	done
}

# The PCR signing keys bind TPM policies to "a UKI signed by this build host".
# Nothing has them yet on the first build, so they are created here: RSA 2048
# (what TPM 2.0 policies support everywhere), root-only, outside the project.
#   - mkosi's (SignExpectedPcrKey=): signs every boot phase, for systemd's own use.
#   - the identity key, next to it: signs the phase enter-initrd only. The
#     machine's secrets are sealed to it (SECURITY.md, "Machine identity"): after
#     the initrd, no signature matches PCR 11 any more, so nothing a root runs can
#     unseal them, even if the initrd never measured the selection.
keys_ensure_pcr() {
	keys_ensure_rsa "$KEYS_PCR_KEY" "$KEYS_PCR_CERT" "safespace expected PCR signing"
	keys_ensure_rsa "$KEYS_ID_KEY" "$KEYS_ID_CERT" "safespace identity PCR signing (enter-initrd)"
}

keys_ensure_rsa() { # KEY CERT CN
	if [[ -f $1 && -f $2 ]]; then
		return 0
	fi
	[[ ! -e $1 && ! -e $2 ]] || die "only one of $1 and $2 exists: restore the other or remove both"
	log "creating the signing key $1 (first build on this host)"
	install -d -m 0700 "$(dirname "$1")" "$(dirname "$2")"
	(
		umask 077
		openssl req -x509 -newkey rsa:2048 -nodes -days 36500 -subj "/CN=$3/" -keyout "$1" -out "$2" 2>/dev/null
	) || die "openssl could not create the signing key $1"
	chmod 0644 "$2"
}
