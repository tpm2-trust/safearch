#!/usr/bin/env python3
# authcheck.py AUTH VARNAME SIGNER_PEM: prints which attributes a signed EFI
# variable update (.auth) is signed for: 0x27 = NV|BS|RT|TIME_BASED_AUTH
# (replace), 0x67 = the same + APPEND_WRITE (append). Used by tests/run.sh.
import struct, subprocess, sys, tempfile, uuid, os

auth, var, signer = sys.argv[1:4]
d = open(auth, 'rb').read()
ts = d[:16]
length, rev, ctype = struct.unpack_from('<IHH', d, 16)
p7 = d[16 + 24:16 + length]          # after WIN_CERTIFICATE_UEFI_GUID header (8 + 16 guid)
data = d[16 + length:]
guid = {'PK': '8be4df61-93ca-11d2-aa0d-00e098032b8c', 'KEK': '8be4df61-93ca-11d2-aa0d-00e098032b8c',
        'db': 'd719b2cb-3d3a-4596-a3bc-dad00e67656f'}[var]

def der_len(n):
    if n < 0x80: return bytes([n])
    b = n.to_bytes((n.bit_length() + 7) // 8, 'big'); return bytes([0x80 | len(b)]) + b

# CertData may be a bare SignedData or a full ContentInfo: wrap if bare.
oid_signed = bytes.fromhex('06092a864886f70d010702')
if p7[2:2 + 11] == oid_signed or p7[4:4 + 11] == oid_signed or oid_signed in p7[:20]:
    ci = p7
else:
    inner = b'\xa0' + der_len(len(p7)) + p7
    body = oid_signed + inner
    ci = b'\x30' + der_len(len(body)) + body

ok = []
with tempfile.TemporaryDirectory() as t:
    open(f'{t}/p7.der', 'wb').write(ci)
    for attrs in (0x27, 0x67):
        msg = var.encode('utf-16-le') + uuid.UUID(guid).bytes_le + struct.pack('<I', attrs) + ts + data
        open(f'{t}/msg', 'wb').write(msg)
        r = subprocess.run(['openssl', 'cms', '-verify', '-binary', '-inform', 'DER', '-in', f'{t}/p7.der',
                            '-content', f'{t}/msg', '-noverify', '-certfile', signer, '-out', os.devnull],
                           capture_output=True)
        if r.returncode == 0: ok.append(hex(attrs))
print(os.path.basename(auth), var, 'signed for', ok or 'NOTHING')
