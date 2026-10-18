# Helpers for signed EFI binaries. Sourced by netboot-export.sh and netstick.sh.

# uefi_signer FILE: print the signer certificate (PEM) of a signed PE/EFI
# binary; fails if the binary carries no Authenticode signature.
uefi_signer() {
	python3 -I - "$1" <<-'EOF' | openssl pkcs7 -inform DER -print_certs 2>/dev/null
		import struct, sys
		d = open(sys.argv[1], 'rb').read()
		opt = struct.unpack_from('<I', d, 0x3c)[0] + 24
		dd = opt + (112 if struct.unpack_from('<H', d, opt)[0] == 0x20b else 96)
		off, size = struct.unpack_from('<II', d, dd + 32)
		if not size: sys.exit('not signed')
		length = struct.unpack_from('<I', d, off)[0]
		sys.stdout.buffer.write(d[off + 8:off + length])
	EOF
}

# uefi_fingerprint FILE: SHA-256 fingerprint of the signer of FILE.
uefi_fingerprint() {
	local pem
	pem=$(uefi_signer "$1") && [[ -n $pem ]] || return 1
	openssl x509 -noout -fingerprint -sha256 <<<"$pem"
}

# uefi_section FILE NAME: print a PE section (e.g. .cmdline) of FILE.
uefi_section() {
	objcopy -O binary --only-section="$2" "$1" /dev/stdout 2>/dev/null | tr -d '\0'
}
