# Signing keys for a build: Secure Boot (sbctl) and expected-PCR signing.
# Sourced by build.sh; expects die() and log(), runs as root.
#
#   keys_load SUMMARY_JSON   read the key settings from `mkosi --json summary`
#   keys_export_secureboot   public Secure Boot material into the image tree
#   keys_ensure_pcr          create the PCR signing key on the first build
#
# Only public material goes into the image: certificates, the signed .auth
# updates and the GUID (secureboot-export.sh). Private keys stay where they
# are; mkosi.postoutput refuses an image tree that contains one.

KEYS_SB_DIR="" KEYS_SB_CERT="" KEYS_PCR_KEY="" KEYS_PCR_CERT=""

keys_load() {
	local summary=$1 sb sb_key
	{ read -r sb; read -r sb_key; read -r KEYS_SB_CERT; read -r KEYS_PCR_KEY; read -r KEYS_PCR_CERT; } < <(
		python3 -I -c '
import json, sys
c = json.load(sys.stdin)["Images"][-1]
for k in ("SecureBoot", "SecureBootKey", "SecureBootCertificate", "SignExpectedPcrKey", "SignExpectedPcrCertificate"):
    v = c.get(k)
    print("" if v is None else v)
' <"$summary") || die "cannot read the key settings from mkosi summary"
	[[ $sb == True ]] || die "SecureBoot= is off: safespace images are always signed"
	[[ $sb_key == */keys/db/db.key ]] ||
		die "SecureBootKey=$sb_key is not in sbctl's layout (<dir>/keys/db/db.key): secureboot-export.sh needs PK and KEK next to it"
	KEYS_SB_DIR=${sb_key%/keys/db/db.key}
	[[ -n $KEYS_PCR_KEY && -n $KEYS_PCR_CERT ]] || die "SignExpectedPcrKey=/SignExpectedPcrCertificate= not set (mkosi.conf)"
}

keys_fingerprint() { openssl x509 -in "$1" -noout -fingerprint -sha256 | cut -d= -f2; }

# Every signed build ships the public half of the keys it is signed with, so
# safespace-seal can enroll them on a machine in Setup Mode. Exported anew on
# every build, so the image can never carry the keys of another key set.
keys_export_secureboot() {
	local here=$1 out=$1/mkosi.extra/usr/share/safespace/secureboot
	"$here/secureboot-export.sh" "$KEYS_SB_DIR" || die "secureboot-export.sh failed"
	[[ $(keys_fingerprint "$out/db.pem") == "$(keys_fingerprint "$KEYS_SB_CERT")" ]] ||
		die "the exported db.pem ($KEYS_SB_DIR) is not SecureBootCertificate=$KEYS_SB_CERT"
}

# The PCR signing key binds TPM policies to "a UKI signed by this build host".
# Nothing has it yet on the first build, so it is created here: RSA 2048 (what
# TPM 2.0 policies support everywhere), root-only, outside the project.
keys_ensure_pcr() {
	if [[ -f $KEYS_PCR_KEY && -f $KEYS_PCR_CERT ]]; then
		return 0
	fi
	[[ ! -e $KEYS_PCR_KEY && ! -e $KEYS_PCR_CERT ]] ||
		die "only one of $KEYS_PCR_KEY and $KEYS_PCR_CERT exists: restore the other or remove both"
	log "creating the PCR signing key $KEYS_PCR_KEY (first build on this host)"
	install -d -m 0700 "$(dirname "$KEYS_PCR_KEY")" "$(dirname "$KEYS_PCR_CERT")"
	(
		umask 077
		openssl req -x509 -newkey rsa:2048 -nodes -days 36500 -subj "/CN=safespace expected PCR signing/" \
			-keyout "$KEYS_PCR_KEY" -out "$KEYS_PCR_CERT" 2>/dev/null
	) || die "openssl could not create the PCR signing key"
	chmod 0644 "$KEYS_PCR_CERT"
}
