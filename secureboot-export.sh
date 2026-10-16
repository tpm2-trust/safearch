#!/usr/bin/env bash
# Export the PUBLIC part of the sbctl Secure Boot keys into the image, so that
# `safespace-seal` on the stick can enroll them on a machine in Setup Mode.
#
#   sudo ./secureboot-export.sh [SBCTL_DIR]      (default: /var/lib/sbctl)
#
# Writes to mkosi.extra/usr/share/safespace/secureboot/:
#   PK.pem KEK.pem db.pem          certificates (public)
#   PK.auth KEK.auth db.auth       signed updates that replace the variable
#   KEK-append.auth db-append.auth signed updates that add to the variable
#   GUID                           signature owner (sbctl's GUID)
# The private keys are only used to sign the .auth files (PK signs PK and KEK,
# KEK signs db, as the UEFI spec requires) and never leave SBCTL_DIR.
# Rerun after rotating keys, then rebuild.
set -Eeuo pipefail

HERE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
SB=${1:-/var/lib/sbctl}
OUT=$HERE/mkosi.extra/usr/share/safespace/secureboot

die() { printf '\e[1;31m==> ERROR:\e[0m %s\n' "$*" >&2; exit 1; }
log() { printf '\e[1;32m==>\e[0m %s\n' "$*"; }

for cmd in cert-to-efi-sig-list sign-efi-sig-list openssl; do
	command -v "$cmd" >/dev/null || die "missing '$cmd' (pacman -S efitools openssl)"
done
for k in PK KEK db; do
	[[ -r $SB/keys/$k/$k.key && -r $SB/keys/$k/$k.pem ]] || die "cannot read $SB/keys/$k/$k.{key,pem} (run with sudo?)"
done
GUID=$(cat "$SB/GUID" 2>/dev/null) || die "no $SB/GUID"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# One timestamp for all updates; firmware rejects updates older than the
# variable's current one, so a fresh export also replaces older enrollments.
ts=$(date -u '+%F %T')
for k in PK KEK db; do
	openssl x509 -in "$SB/keys/$k/$k.pem" -out "$TMP/$k.pem"
	cert-to-efi-sig-list -g "$GUID" "$TMP/$k.pem" "$TMP/$k.esl" >/dev/null
done
sign() { # signer var esl out [-a]
	sign-efi-sig-list ${5:-} -t "$ts" -k "$SB/keys/$1/$1.key" -c "$SB/keys/$1/$1.pem" "$2" "$3" "$4" >/dev/null
}
sign PK PK "$TMP/PK.esl" "$TMP/PK.auth"
sign PK KEK "$TMP/KEK.esl" "$TMP/KEK.auth"
sign PK KEK "$TMP/KEK.esl" "$TMP/KEK-append.auth" -a
sign KEK db "$TMP/db.esl" "$TMP/db.auth"
sign KEK db "$TMP/db.esl" "$TMP/db-append.auth" -a
echo "$GUID" >"$TMP/GUID"

rm -rf "$OUT"
mkdir -p "$OUT"
cp "$TMP"/{PK,KEK,db}.pem "$TMP"/*.auth "$TMP/GUID" "$OUT/"
chmod 0644 "$OUT"/*
# Keep the project owned by its user, not by root.
chown -R --reference="$HERE" "$HERE/mkosi.extra/usr/share/safespace"

log "Exported to ${OUT#"$HERE"/}:"
for k in PK KEK db; do
	printf '    %-4s %s, valid until %s\n' "$k" \
		"$(openssl x509 -in "$OUT/$k.pem" -noout -subject -nameopt oneline | sed 's/^subject=//')" \
		"$(openssl x509 -in "$OUT/$k.pem" -noout -enddate | cut -d= -f2)"
done
log "Rebuild the image to include them (sudo mkosi -f build)."
