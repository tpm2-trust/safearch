# Netboot: booting safespace-arch over the network

Every build of safespace-arch boots from a stick **and** over the network. Over the
network, the firmware downloads the signed UKI (kernel + initrd + signed command line), and
the initrd downloads the read-only root image and its dm-verity hash tree into RAM. The
client writes nothing, anywhere — it has no boot medium at all. (The initrd knows it was
loaded over the network because `LoaderDevicePartUUID` is not set: no boot loader started
it from a partition.)

**The whole path, for an x86-64 UEFI machine:**

1. on the build host: `sudo ./build.sh` — [Build and release](#build-and-release)
2. on the build host: `./release.sh --push safespace@SERVER` — the same section;
   it replaces the server's release, and the server checks it
3. once on the server: `sudo server/setup.sh …` (nginx, the check, optional
   dnsmasq) — [The distribution server](#the-distribution-server)
4. on the machine: switch network boot on in the firmware and boot it —
   [Boot a real machine](#boot-a-real-machine)

Nothing else is needed; `./test-vm.sh --netboot` is only an optional rehearsal in QEMU.

This file is the reference and uses a generic distribution server at `10.0.0.1`. The
commands in order, per role (build host, distribution server), are in README.md,
["Two roles"](README.md#two-roles-build-host-and-distribution-servers).

```
  machine (UEFI, Secure Boot on)                 server
  ──────────────────────────────                 ──────
  1. DHCP: "where do I boot from?"  ───────────▶ DHCP: http://10.0.0.1/safespace/boot.efi
  2. HTTP GET /safespace/boot.efi ▶ nginx
     firmware verifies the signature against db
  3. UKI starts: kernel + initrd, command line fixed at build time
     (safespace.root.<name>=… per combination, safespace.netroot=http://10.0.0.1/safespace/)
  4. initrd: picks the combination (EFI variable, else the first), DHCP, then
     HTTP GET /safespace/roothash-<name>    ──▶ nginx   (still this UKI's release?)
     HTTP GET /safespace/root-<name>.verity ──▶ nginx
     HTTP GET /safespace/root-<name>.img    ──▶ nginx   (into a tmpfs)
  5. veritysetup open … <its signed hash>  → /dev/mapper/root
  6. root mounted read-only, /var is a tmpfs, machine is independent of the
     server from here on
```

**The machine needs nothing local for this.** There is no boot medium, no bootloader and no
file on a disk: UEFI firmware has its own network stack. Put the network device in the boot
order (or pick it from the boot menu), and the firmware does DHCP itself, takes the boot file
from the DHCP answer, downloads it into memory and starts it. All that is needed from the
machine is a NIC the firmware supports and "network boot" enabled; everything else is the
server's answer. A machine whose firmware cannot do that at all boots the same build from a
stick instead; see [Old firmware](#old-firmware-the-thinkpad-t450s).

**Everything the client trusts is inside the signed UKI**, nothing comes from the
server unverified:

| What | Where it comes from | If the server lies |
|---|---|---|
| kernel, initrd, command line | the UKI, signed with your sbctl `db` key, checked by the firmware | firmware refuses to start it |
| which URL to load root from | `safespace.netroot=` on the signed command line | cannot be changed |
| root filesystem | `root-<name>.img`, checked against `safespace.root.<name>=` from the signed command line (an EFI variable only names the combination) | `veritysetup` refuses to open it, every later block is checked by dm-verity (`--panic-on-corruption`) |

So plain HTTP is enough: an attacker on the network can keep a machine from booting,
but cannot change what it boots. HTTPS only adds confidentiality, and needs a
certificate that curl in the initrd trusts.

## Scope: x86-64 UEFI only

Only **x86-64 UEFI** machines are supported. The boot file is a UEFI PE binary (the signed
UKI), so a machine booting in legacy BIOS/CSM mode cannot start it at all — turn CSM/legacy
boot off and use the UEFI network boot entries. There is no BIOS/pxelinux path, no 32-bit
(IA32) UEFI and no other architecture; the DHCP configuration below deliberately answers
only UEFI x86-64 clients.

## Which of the scripts you actually need

| | Where | What it is for | Needed for a real machine? |
|---|---|---|---|
| `./build.sh` | build host | builds the image (for sticks and network boot alike) | **yes** |
| `./release.sh` | build host | the **release step**: turns mkosi's output into the files the firmware and the initrd ask for (`boot.efi`, `root-<name>.img`, `root-<name>.verity`), checks them, pushes them to the distribution servers | **yes** |
| `server/setup.sh` | distribution server | nginx, the check after every upload, optionally dnsmasq (`safespace-dhcp`) | **yes**, once per server |
| `./test-vm.sh --netboot` | build host | a rehearsal in QEMU before you touch hardware | no, optional |

Nothing is installed on the machine itself, and the machine needs no local file. See
[Boot a real machine](#boot-a-real-machine).

## What a client needs

- **UEFI HTTP Boot** (any recent firmware; "UEFI HTTP Boot" or "Network Stack → HTTP")
  or, as a fallback, classic **PXE/TFTP** — much slower for a ~100 MiB UKI.
  Firmware usually offers both as separate boot entries ("UEFI HTTPv4 …", "UEFI PXEv4 …").
  Prefer the HTTP entry; a PXE entry that is tried first and gets an HTTP URL as its boot
  file fails with `PXE-E23` and the firmware moves on to the next entry. The dnsmasq
  configuration below avoids that by answering each client according to what it asks for.
  **UEFI HTTP boot is the intended path**: the firmware downloads the signed UKI itself
  and checks it against `db`, no extra loader in between. PXE/TFTP is only the
  alternative for older machines whose firmware has no HTTP boot (e.g. the ThinkPad
  T450s, [Case found](#case-found-thinkpad-t450s-bios-jbet73ww)); it starts the same
  signed UKI directly. No iPXE in either path.
- **A PCI/PCIe NIC.** USB NICs do not work: the kernel authorizes no USB device
  (`usbcore.authorized_default=0`), and over the network there is no initrd step that
  authorizes anything (only the stick path authorizes the way to its stick).
- **RAM for the root image plus the system.** The booted combination's `root-<name>.img`
  lives in a tmpfs for as long as the machine runs (erofs, decompressed on read), so budget
  `size of that root image (~2 GiB, more with the desktop) + 2 GiB`, i.e. 8 GiB to be comfortable. The initrd
  checks `MemAvailable` before downloading and says so if it is not enough.
- **Your `db` certificate enrolled**, if Secure Boot is to be enforced — see
  [Secure Boot on the clients](#secure-boot-on-the-clients).
- A data disk labelled `safespace-docker` on SATA/NVMe if Docker is used (as from a
  stick; see README).

## Build and release

Once per build host: `users.conf` and `safespace.env`. The public Secure Boot keys for
`safespace-seal` are exported by `build.sh` on every build. Then set the URL of the
distribution servers (`SERVER_URL` of their `server.conf` + `/`):

```sh
cp netboot.conf.example netboot.conf     # NETROOT_URL=http://10.0.0.1/safespace/
sudo ./build.sh                          # the whole stack -> mkosi.output/combined_<time>/
./release.sh --push safespace@10.0.0.1
```

`build.sh` signs `NETROOT_URL` into the UKI as it is. A distribution server holds one
release, in its share (`/srv/safespace/share/`, served as `http://10.0.0.1/safespace/`):

```
/srv/safespace/share/
├── boot.efi             the signed UKI (what the firmware downloads), all combinations
├── root-<name>.img      per combination: erofs root partition, ~2 GiB (dm-verity data)
├── root-<name>.verity   its dm-verity hash tree, ~17 MiB
├── roothash-<name>      its root hash (the initrd compares it first)
├── manifest-<name>.json its packages
├── systemd-boot.efi, layout.sfdisk    for writing sticks (burn.sh)
└── cmdline, release, SHA256SUMS
```

`release.sh` refuses to release artifacts that do not belong together: it checks the
signatures against the exported `db.pem`, requires `lockdown=integrity` on the UKI's signed
command line, compares each root hash there with the build's, runs `veritysetup verify` over
every root image and checks the partition table for sticks — so a bad set is caught on the build host instead of on 50
machines. Every distribution server repeats exactly these checks (`lib/verify.sh`) after the
upload and reports the result.

**Replacing a release while machines boot:** the files are renamed into place in one go at the
end of the upload (`rsync --delay-updates`), and a download already running finishes on the
old file. A machine that got the old `boot.efi` and then asks for the root image fetches
`roothash-<name>` first: if the server has another release by now, it reboots after 10 s and the
firmware loads the new `boot.efi`. If the image is refused although the server still claims
this UKI's release, that is a real error and the boot stops (no reboot loop).

**Which combination** (README "Combinations"): the initrd picks it (`safespace.select=`, the
EFI variables set by `safespace-select`, else the first of `combinations.conf`) and downloads
only that root. Without `safespace.root.<name>=` on the signed command line it opens nothing.

## The distribution server

A distribution server needs two things for network boot: an HTTP server for the files and a
DHCP answer that names the boot file. `server/setup.sh` sets up the first (nginx on the
share, plus the check of every upload), and optionally the second
(`safespace-dhcp`, dnsmasq: `DHCP_MODE=proxy` or `dhcp`). It stores nothing secret:
everything in the share is public and signed; the only key it holds is the public `db.pem`.
Commands, settings and services: README.md,
["Distribution server"](README.md#distribution-server).

### 1. HTTP

nginx serves the share read-only: `/etc/nginx/conf.d/safespace.conf` (from
`server/nginx/safespace.conf`), GET/HEAD only, no listing, no hidden files. Check from another
machine:

```sh
curl -I http://10.0.0.1/safespace/boot.efi    # 200 OK and a Content-Length
```

`Content-Length` matters: the initrd uses it to size the tmpfs and to check that there
is enough RAM before it starts downloading.

### 3. DHCP and the boot file

Only two things have to reach the machine, whatever DHCP server you run:

| DHCP option | HTTP boot (the fast path) | PXE/TFTP fallback |
|---|---|---|
| 60, vendor class identifier | `HTTPClient` | — |
| 67, boot file name | `http://10.0.0.1/safespace/boot.efi` (full URL) | `boot.efi` (path under the TFTP root = the share) |
| 66 / `next-server` (siaddr) | — | `10.0.0.1`, the TFTP server |

There is no third thing: no agent, no per-machine entry, no MAC list. The address the
machine gets is its normal lease.

**Send them only to the clients that asked for them.** A machine says what it is in its
request: option 60 starts with `HTTPClient:Arch:00016` and option 93 (client
architecture) is `16` for x86-64 UEFI HTTP boot, `7` or `9` for x86-64 UEFI PXE. A firmware
that starts its PXE entry and receives an HTTP URL fails with `PXE-E23`, so the two answers
must be kept apart — that is all the conditions in the examples below do. Legacy BIOS
clients (option 93 = `0`) get no answer at all: the boot file is a UEFI binary.

#### dnsmasq: `safespace-dhcp` on the distribution server

`DHCP_MODE=` in `/etc/safespace/server.conf` picks one of the two cases; on every start the
service writes the configuration from the settings (`safespace-netboot dnsmasq-config`, into
`/run/safespace-dhcp/dnsmasq.conf`) and runs dnsmasq with it, TFTP rooted at the share.

**Case A — `DHCP_MODE=dhcp`: dnsmasq is the DHCP server** for this network (e.g. a dedicated
boot VLAN). Generated from `DHCP_INTERFACE`, `DHCP_RANGE`, `DHCP_ROUTER`, `DHCP_DNS`,
`SERVER_URL` and `DHCP_CHANNEL`:

```ini
interface=eth0
bind-interfaces
port=0
dhcp-match=set:efi64,option:client-arch,7
dhcp-match=set:efi64,option:client-arch,9
dhcp-range=10.0.0.100,10.0.0.199,12h
dhcp-option=option:router,10.0.0.1
dhcp-option=option:dns-server,10.0.0.1
# UEFI HTTP Boot (the normal path): the client announces itself as HTTPClient
# with architecture 00016 = x86-64 UEFI HTTP. The reply has to repeat the
# vendor class and give the full URL as the boot file.
dhcp-vendorclass=set:httpclient,HTTPClient:Arch:00016
dhcp-match=set:httpclient,option:client-arch,16
dhcp-option-force=tag:httpclient,60,HTTPClient
dhcp-boot=tag:httpclient,http://10.0.0.1/safespace/boot.efi
# Fallback for UEFI machines without HTTP boot: PXE over TFTP. client-arch 7
# and 9 are x86-64 UEFI; legacy BIOS (0) and IA32 UEFI (6) get no answer.
dhcp-boot=tag:efi64,boot.efi
enable-tftp
tftp-root=/srv/safespace/share
log-dhcp
conf-dir=/etc/safespace/dnsmasq.d/,*.conf
```

Answering each client according to what it asked for is what keeps a machine from running
into `PXE-E23`: a firmware that starts its PXE entry would otherwise get an HTTP URL and
try to fetch it over TFTP.

**Case B — `DHCP_MODE=proxy`: there is already a DHCP server** and you must not replace it.
dnsmasq only answers the boot question, the existing server keeps handing out addresses
(`DHCP_PROXY_SUBNET` is the LAN's network address):

```ini
dhcp-range=10.0.0.0,proxy
pxe-service=tag:efi64,x86-64_EFI,"safespace netboot",boot.efi
```

(plus the interface, `dhcp-match`, TFTP and log lines as above). Proxy mode reliably drives
the **TFTP** path only: UEFI HTTP boot wants the URL and the vendor class from the DHCP
server that owns the network.

```sh
journalctl -u safespace-dhcp -f        # watch a client boot
```

Site additions (extra options, per-host settings) go into
`/etc/safespace/dnsmasq.d/*.conf`.

#### ISC dhcpd (`dhcpd.conf`)

```
option arch code 93 = unsigned integer 16;

# UEFI HTTP boot: answer with the vendor class and the full URL.
class "safespace-http" {
    match if substring(option vendor-class-identifier, 0, 10) = "HTTPClient";
    option vendor-class-identifier "HTTPClient";
    filename "http://10.0.0.1/safespace/boot.efi";
}

# UEFI PXE (x86-64): a path under the TFTP root plus the TFTP server.
class "safespace-pxe" {
    match if option arch = 7 or option arch = 9;
    filename "boot.efi";
    next-server 10.0.0.1;
}
```

The classes go next to the existing subnet declaration; the subnet keeps handing out
addresses as before. (ISC dhcpd is no longer developed upstream — on a new server prefer
Kea.)

#### Kea (`kea-dhcp4.conf`)

```json
"client-classes": [
  {
    "name": "safespace-http",
    "test": "substring(option[60].hex,0,10) == 'HTTPClient'",
    "boot-file-name": "http://10.0.0.1/safespace/boot.efi",
    "option-data": [
      { "name": "vendor-class-identifier", "data": "HTTPClient" }
    ]
  },
  {
    "name": "safespace-pxe",
    "test": "option[93].hex == 0x0007 or option[93].hex == 0x0009",
    "next-server": "10.0.0.1",
    "boot-file-name": "boot.efi"
  }
]
```

#### Routers, firewalls and Windows Server

- **OPNsense / pfSense:** *Services → DHCPv4 → \[interface\]*. For the PXE path use
  "Network booting": next-server `10.0.0.1`, filename `boot.efi`. For
  HTTP boot add the two options under "Additional BOOTP/DHCP Options": number 60, type
  string, value `HTTPClient`, and number 67, type string, value with the full URL.
- **Windows Server DHCP:** option 067 (Bootfile Name) takes the URL; option 060 has to be
  defined once (`netsh dhcp server add optiondef 60 HTTPClient STRING 0`) and then set to
  `HTTPClient`. Put both into a DHCP *policy* whose condition is the vendor class
  `HTTPClient*`, so other clients are unaffected.
- **Consumer routers (Fritz!Box and friends)** usually cannot set options 60/67 at all. Use
  `DHCP_MODE=proxy` on the distribution server (Case B): it adds only the boot answer and
  leaves the router's DHCP alone.

### 4. Firewall

On the distribution server; DHCP and TFTP only with `DHCP_MODE`:

```nft
tcp dport 22 accept             # ssh: uploads from the build host (restricted account)
tcp dport 80 accept             # HTTP: UKI and root images
udp dport 4011 accept           # proxy DHCP (DHCP_MODE=proxy)
udp dport 67 accept             # DHCP
udp dport 69 accept             # TFTP (PXE fallback only)
```

## Boot a real machine

Nothing is installed on the machine and nothing is prepared on it: it only has to be told
to boot from the network. Everything else comes from the server.

**1. Firmware setup** (names differ per vendor):

| Setting | Value |
|---|---|
| CSM / Legacy boot / "Boot mode" | **off / UEFI only** — the boot file is a UEFI binary |
| Network stack / "UEFI Network Stack" | on |
| UEFI HTTP boot (IPv4) | on, if the firmware lists it separately |
| PXE boot (IPv4) | on if you use the TFTP fallback, otherwise it can stay off |
| Boot order | the network entry first, or just press the one-time boot menu key (F12/F9/F8/Esc) and pick **"UEFI HTTPv4 …"** (or "UEFI PXEv4 …") |
| Wake/boot from the right port | if the machine has several NICs, enable it for the one that is plugged in |

**2. Secure Boot:** either enroll your `db` certificate first, or boot once in Setup Mode and
let the machine seal itself — see [Secure Boot on the clients](#secure-boot-on-the-clients).
Both work; the second needs no stick.

**3. Boot it.** What you should see:

- the firmware reports a DHCP address and the URL it downloads, e.g.
  `>>Start HTTP Boot over IPv4....  Station IP address is 10.0.0.137`, then
  `Downloading...100%`,
- the kernel starts, and the initrd logs its progress on the console (and into the journal):

```
netroot: waiting up to 60s for a DHCP address
netroot: link up: enp1s0 10.0.0.137/24
netroot: fetching the root image from http://10.0.0.1/safespace
netroot: combination root (no selection: the first), roothash=ea0e130f2f63...
netroot: root-root.img 2013 MiB + root-root.verity 16 MiB, 15822 MiB RAM free
netroot: got root-root.verity: 16 MiB in 1s (16 MiB/s)
netroot: got root-root.img: 2013 MiB in 19s (105 MiB/s)
netroot: root opened as /dev/mapper/root (/dev/loop0 = /run/netroot/root.img), verified against roothash=ea0e130f2f63...
```

**4. Check it on the machine** (ssh in with a key from `users.conf`, or at the console):

```sh
journalctl -b -g netroot      # the lines above, from this boot
findmnt /                     # /dev/mapper/root, erofs, ro
veritysetup status root       # verity device, read-only, the root hash from the UKI
df -h /run/netroot            # the root image in RAM (tmpfs), as large as root-<name>.img
bootctl status                # "Secure Boot: enabled" once the machine is sealed
cat /proc/cmdline             # the signed command line incl. safespace.netroot=
```

On the server side, one boot shows up as three requests in nginx's access log:
`boot.efi`, `root-<name>.verity`, `root-<name>.img`.

**5. Repeat for the next machine** — there is nothing per-machine to do except the firmware
settings and, if you enforce Secure Boot, the key enrollment.

If it does not boot, the firmware's own message says which step failed; see
[Troubleshooting](#troubleshooting).

### Quick one-off test on an existing LAN

To try a real machine before setting up a dedicated server, make the build host a
distribution server for the time of the test: the only thing the LAN's own DHCP server will
not tell the machine is where to boot from, and dnsmasq in proxy mode adds just that answer
without handing out addresses, so the existing DHCP server is untouched. This works for
**PXE only**: dnsmasq in proxy mode answers only clients that announce `PXEClient`, so UEFI
HTTP boot (options 60/67) always needs the DHCP server that hands out the address.

```sh
# 1. the build host as distribution server (192.168.1.10 = its address on the LAN)
sudo server/setup.sh --db-cert mkosi.extra/usr/share/safespace/secureboot/db.pem --upload-key ~/.ssh/safespace-release.pub
sudo sed -i -e 's|^SERVER_URL=.*|SERVER_URL=http://192.168.1.10/safespace|' \
            -e 's|^DHCP_MODE=.*|DHCP_MODE=proxy|' -e 's|^DHCP_INTERFACE=.*|DHCP_INTERFACE=eth0|' \
            -e 's|^DHCP_PROXY_SUBNET=.*|DHCP_PROXY_SUBNET=192.168.1.0|' /etc/safespace/server.conf
sudo server/setup.sh                       # starts safespace-dhcp in proxy mode

# 2. build for it and release to it (ssh to itself with the upload key)
sudo ./build.sh --url http://192.168.1.10/safespace/
./release.sh --push safespace@localhost
safespace-netboot status                    # network <version> ..., ok

# 3. on the test machine: one-time boot menu -> "UEFI PXEv4 ..."
journalctl -u safespace-dhcp -f
```

Afterwards `sudo systemctl disable --now safespace-dhcp`, or
`DHCP_MODE=off` and rerun `server/setup.sh`.

A firewall between the machine and the build host has to let through UDP 67 and 4011 (proxy
DHCP) and UDP 69 (TFTP; the data then comes from ephemeral ports, which a stateful firewall lets back in
as established traffic). `tftp-single-port` is not used: together with `bind-interfaces`
dnsmasq 2.93 sends no TFTP reply at all. Proxy DHCP only works on the
machine's own L2 segment: a build host in a VM behind NAT never sees the broadcasts.

In this mode the ~82 MiB UKI comes over TFTP, which takes about a minute; the ~2 GiB root
image still comes over HTTP at full speed. For the fast path configure the real DHCP server
(options 60/67), or give the test machines their own VLAN with `DHCP_MODE=dhcp`
([Case A](#3-dhcp-and-the-boot-file)).

## Secure Boot on the clients

The firmware checks a downloaded boot file exactly like one from an ESP: the UKI's
signature must match a certificate in `db`. So nothing special is needed for netboot —
but the `db` certificate has to be on the machine. Three ways, all using the keys that
`build.sh` exports into every image (README.md, ["Secure Boot keys"](README.md#secure-boot-keys)):

1. **Seal from the netboot itself** (no stick needed). Firmware setup: *Reset to Setup
   Mode* / *Clear Secure Boot keys*. With no keys enrolled, Secure Boot cannot be
   enforced, so the machine netboots. Then on the machine:
   ```sh
   sudo safespace-seal          # enrolls db, KEK, PK (see README, "Sealing")
   ```
   Reboot, check that Secure Boot is on, set a firmware password. From now on the
   machine only boots UKIs signed with your `db` key — including the one it downloads.
2. **Seal from a stick**: `sudo ./burn.sh /dev/sdX` (the same build), boot it
   once per machine, `sudo safespace-seal`. Useful when netbooting in Setup Mode is not
   possible.
3. **Enroll by hand in firmware setup**: most firmwares can load `db`/`KEK`/`PK` from a
   FAT medium. The files are in
   `mkosi.extra/usr/share/safespace/secureboot/` (`db.auth`, `KEK.auth`, `PK.auth`, or
   the `.pem`/`.der` form, depending on the firmware). You can also publish them in the
   netboot tree — they are public.

Notes:

- `safespace-seal` **adds** your keys by default and keeps vendor/Microsoft
  certificates, so option ROMs of GPUs and NICs still load. That matters more here than
  for a stick: the NIC's own option ROM is what does HTTP boot. Do not use
  `--replace` on a machine that netboots through an add-in NIC.
- A **firmware password** is part of the protection: without it, anyone can turn
  Secure Boot off, or boot a different URL.
- `release.sh` and the distribution servers only accept a UKI that verifies against the
  `db.pem` shipped in the image (a sealed machine would refuse anything else).
- Rotating keys means: new keys in sbctl, rebuild (the build exports them), give the servers
  the new `db.pem` (`server/setup.sh --db-cert … --replace-db-cert`), release, and re-seal
  the machines (the enrollment files carry a newer timestamp, so they replace the old ones).

## A host name instead of an IP address

Both URLs can be host names, and they are resolved by different parties:

| URL | Who resolves it | What it needs |
|---|---|---|
| the boot file in the DHCP answer (option 67) | the **firmware** | a DNS server in the DHCP answer that the firmware's own resolver can use. It works on most firmware, but it is one more thing that can fail before anything of yours runs — an IP address here is the safest choice |
| `safespace.netroot=` inside the UKI | the **initrd** | the same DNS servers from the initrd's own DHCP lease |

In the initrd there is no systemd-resolved and no `/etc/resolv.conf` to fill in: curl resolves
through nss-resolve, which **systemd-networkd** answers over its resolve-hook socket with the
DNS servers from the DHCP lease. That path is part of mkosi's initrd and was verified in the
QEMU lab (a name resolved and fetched over HTTP from inside the initrd). So a name works as
soon as the DHCP answer carries a resolver that knows it, and `netroot` logs curl's own
`Could not resolve host …` if it does not.

A name is worth it when the server may move, because the URL is signed into the UKI and
otherwise means a rebuild. Two practical notes:

- Use a name you control in your own zone (`boot.example.internal`), not one that depends on
  a search domain — the initrd resolves exactly the string in the URL.
- `NETROOT_URL` takes several URLs, tried in order, so you can have both and let the name be
  the first choice and a fixed address the fallback:

  ```sh
  NETROOT_URL="http://boot.example.internal/safespace/ http://10.0.0.1/safespace/"
  ```

  A failed lookup then costs a few seconds before the second URL is used, and nothing else.

## Rebuilding and rolling out a new image

Everything that changes the image — packages, groups, users, `mkosi.extra/`, a new package
snapshot — needs a rebuild and a new release. The version (build timestamp) is part of
every file name and of the URL inside the UKI, so builds never overwrite each other.

```sh
# 1. change what you want, e.g.
./update-snapshot.sh                 # newest Arch Linux Archive day (repos.conf)
vim users.conf mkosi.conf            # users, packages, …
./fetch-images.sh                    # shipped Docker images (docker group)

# 2. build (-f also rebuilds unchanged packages, -ff reinstalls everything)
sudo ./build.sh -f                   # every combination of combinations.conf

# 3. release: replaces the release on every server, which then checks it
./release.sh
```

The new files are renamed into place in one go at the end of the upload, so machines keep
booting the old release until that moment; a machine caught in between reboots once and
then loads the new one (see [Build and release](#build-and-release)).

**Going back** is a release of an older build from the build host:
`./release.sh --build <older build>` (`./build.sh list`). The server has no rollback of its own: it
always serves exactly what the build host sent last.

Machines take the new (or old) version on their next boot; a running machine is not
affected, it has everything in RAM.

**Disk space:** ~2.2 GiB on every server; on the build host ~2.2 GiB per build in
`mkosi.output/` (the staged release in `mkosi.release/` is hardlinks). `./build.sh prune`
removes old builds, `sudo ./build.sh purge-cache` the caches.

## Optional: rehearse it in QEMU first

This is only a rehearsal on the build host — it is not needed for, and says nothing about,
a particular piece of hardware. It is useful to check the artifacts, the initrd and the
Secure Boot signature before carrying anything into a server room.

A published build, from the real server, by pure UEFI HTTP boot (no local server, no
special build; the VM reaches the server through QEMU's NAT and resolves names through the
host):

```sh
./test-vm.sh --netboot --url http://10.0.0.1/safespace/boot.efi --ssh 2222
./test-vm.sh --netboot --url http://10.0.0.1/safespace/boot.efi --setup-mode --ssh 2222   # then safespace-seal inside, then --sealed
```

A netbooting VM of its own (plain QEMU, or a persistent libvirt machine for virt-manager,
with PXE switched off in OVMF so it goes straight to HTTP boot):
[README, "A netbooting VM"](README.md#a-netbooting-vm-qemu-libvirt--virt-manager).

Or a self-contained lab on the build host:

```sh
# built for the VM: QEMU's user network is the host at 10.0.2.2, and the
# console= part puts the kernel and netroot messages into mkosi.test/serial.log
sudo ./build.sh --url http://10.0.2.2:8000/ \
     --kernel-command-line console=ttyS0,115200
./release.sh                           # stage only: mkosi.release/
./test-vm.sh --netboot                 # add --ssh 2222 to log in
```

The VM gets no disk at all. QEMU's user network is the DHCP server, `test-vm.sh --netboot`
serves `mkosi.release/` over HTTP on `127.0.0.1:8000` (a symlink farm, so the path inside
the signed URL resolves), and the firmware boots the way a real machine does. `--tftp`
switches the UKI download to QEMU's built-in TFTP server, for firmware without HTTP boot.
With `--secure-boot` the VM boots with enforced Secure Boot and only the UKI's own
certificate in `db` — the closest thing to a sealed machine. `MEM=` overrides the RAM
(default: root image + 2 GiB), `QEMU_EXTRA='-display none'` runs it headless.

This is what a successful run looks like in `mkosi.test/serial.log` (OVMF, the firmware's
own output):

```
>>Start HTTP Boot over IPv4....
  Station IP address is 10.0.2.15
  Downloading...100%
BdsDxe: starting Boot0004 "UEFI HTTPv4 (MAC:525400123456)" … /Uri()
netroot: waiting up to 60s for a DHCP address
netroot: fetching the root image from http://10.0.2.2:8000
netroot: got root-root.verity: 15 MiB in 1s
netroot: got root-root.img: 1956 MiB in 15s (130 MiB/s)
netroot: root opened as /dev/mapper/root (/dev/loop0 = /run/netroot/root.img)
[  OK  ] Mounted /sysroot.
…
safespace login:
```

After QEMU exits, `test-vm.sh` prints which steps of that chain it found in the log, and
which files the VM asked the HTTP server for. With `--ssh 2222` you can log in and look
around: `journalctl -b -g netroot`, `findmnt /`, `df -h /run/netroot`,
`veritysetup status root`.

## Old firmware: the ThinkPad T450s

Machines whose firmware has no usable network boot boot the same build from a stick. The
one case found so far, and how it was solved without a stick:

### Case found: ThinkPad T450s (BIOS JBET73WW)

**Result:** with **Intel AMT disabled** in the BIOS (*Config → Intel AMT → Intel AMT
Support: Disabled*) the T450s network-boots over PXE/TFTP, as long as the UKI stays
below the firmware's size limit for network boot programs: images of 17, 48, 80 and
82 MiB start, 112 MiB does not (the limit is somewhere in between). That is why the
network UKI is trimmed (see [Size of the network UKI](#size-of-the-network-uki)).
**Verified end to end** with the trimmed 82 MiB UKI (`20261018-1559-debug`): firmware
PXE → TFTP download → UKI starts → DHCP in the initrd → `root.verity` and `root.img`
over HTTP → verified root mounted → login over ssh. No iPXE, no stick.

This is the path for old machines without UEFI HTTP boot; machines with HTTP boot use
that (the intended path, also without iPXE). A machine where AMT has to stay on boots from a
stick.

**What it looked like with AMT enabled:** the firmware offers only PXE (no HTTP boot
entry). Every file arrives completely (dnsmasq logs `sent …`), yet nothing the firmware
loaded over the network ever ran: the UKI, systemd-boot, systemd-stub + kernel and the EFI
shell all rebooted, hung or went back to the boot menu, while the same UKI booted from a
USB stick. The NIC (Intel I218-LM, vPro) is shared with the Intel ME, and the firmware's
AMT drivers leave its network stack in a state where the next image cannot be started.
Disabling AMT fixed it; what remained was the size limit above (a padded test image of
the same size behaved the same, so it is the size, not the UKI's content).

How to recognise the case on another machine: the files are delivered completely
(dnsmasq `sent …`, nginx `200` with the full size), yet the machine reboots, returns to
the boot menu or hangs without a single kernel message, also for small images.

## Size of the network UKI

Firmware loads the UKI as a network boot program, and some firmware cannot start a
large one (T450s: 82 MiB fine, 112 MiB not). **The current size, 82 MiB, is fine**; the
80 MiB warning only marks the largest size tested before the trimmed build, not a
limit. `mkosi.postoutput` prints the size of each
part of the network UKI, **warns above 80 MiB** and stops the build above 128 MiB
(per host: `Environment=SAFESPACE_UKI_WARN_MIB=… SAFESPACE_UKI_LIMIT_MIB=…` in
`mkosi.local.conf`).

| Part | Size | |
|---|---|---|
| kernel | ~16 MiB | fixed |
| microcode | ~16 MiB | all Intel CPUs; kept, it carries CPU security fixes |
| initrd | ~48 MiB (78 MiB untrimmed) | trimmed for the netroot path |
| **UKI** | **~82 MiB** (112 MiB untrimmed) | boots over PXE on the T450s |

The initrd only has to bring up the NIC or find the stick, verify the root and mount it,
so it trims what mkosi's default initrd brings along:

- **Drivers** (`KernelInitrdModules=` in `mkosi.conf`): an explicit list instead of
  mkosi's default set — dm-verity, loop, erofs, crypto, virtio_net for QEMU, USB host
  controllers, USB storage, MMC and card readers (~1 MiB, for the stick path), and the
  client NIC families (Intel e1000/e1000e/igb/igc/ixgbe, Realtek, Broadcom tg3/b44,
  Marvell sky2, Atheros, Aquantia, AMD pcnet32) with PHY/MDIO helpers. No server NICs
  (Mellanox, QLogic, Chelsio, Solarflare, Intel i40e/ice, Broadcom bnx2x …) and their
  firmware, no other storage or filesystem drivers. To netboot a machine with another NIC,
  add its driver there.
- **Programs** (`mkosi.initrd.conf/mkosi.conf`, `RemoveFiles=`): filesystem tools (btrfs,
  xfs, ext4, vfat), systemd tools without a job in the initrd, glibc's charset converters,
  the gcc sanitizer runtimes, certificate CLIs, and terminal/timezone/keymap data beyond
  the console defaults.

The 82 MiB in the table above are from the network-only builds before; the single build
carries the stick path's drivers too (~1 MiB more). `mkosi.postoutput` warns above 85 MiB.

Cosmetic: mkosi copies the kernel's full module index into the initrd (all ~6500 modules,
of which ~200 are shipped), so udev in the initrd logs `error=No such file or directory`
for drivers of hardware it finds but has no module for (kvm, mei, wmi, sound, ...). The
real system loads them from the root image.

## Troubleshooting

| Symptom | Where to look |
|---|---|
| firmware never asks for DHCP | network stack / HTTP boot disabled in firmware, not in the boot order, or the cable is in another NIC than the one that is enabled |
| "unsupported image", "invalid boot file" or the firmware restarts the boot menu | the machine booted in legacy BIOS/CSM mode: the boot file is a UEFI binary. Set the firmware to UEFI only and use the "UEFI …" network entry |
| DHCP but no download | `journalctl -u safespace-dhcp -f` (or your DHCP server's log): does the client get option 60/67? HTTP boot needs both. `curl -I` the URL from another machine |
| firmware downloads, then "Access Denied" / nothing | Secure Boot is enforced but `db` does not have your certificate: seal the machine (see above). `release.sh` and `safespace-netboot verify` say which key signed it |
| firmware resets or hangs on the download | the UKI may be too large for this firmware: shrink it (`KernelInitrdModules=` in `mkosi.conf`, e.g. only `/drivers/net/ethernet/intel/`) and rebuild; or use the usb variant |
| `netroot: no link reported as online` | NIC driver missing in the initrd (add it to `KernelInitrdModules=`), no DHCP on that port, or the NIC is on USB (not supported) |
| `netroot: not enough RAM` | the machine cannot hold the root image; more RAM, or a smaller image (fewer packages) |
| `netroot: download … failed` | nginx not running, wrong path, or firewall; the message contains curl's own error |
| `netroot: dm-verity refused the image` | `root-<name>.img`/`.verity` in that directory are not the ones the UKI was signed for: release it again with `release.sh` (it checks this before pushing; `safespace-netboot status` on the server says whether what it serves is broken) |
| the screen says `Start PXE over IPv4`, `Station IP address …`, but nginx sees nothing | that is the firmware's **PXE** client, not HTTP boot: it wants a TFTP file name and a TFTP server, an HTTP URL in option 67 fails. Enable HTTP boot and pick the "HTTPv4" entry, or serve the UKI over TFTP (dnsmasq `pxe-service` / proxy DHCP, [Quick one-off test](#quick-one-off-test-on-an-existing-lan)) |
| proxy DHCP (dnsmasq) logs nothing when the client boots | the broadcasts do not reach dnsmasq: another L2 segment (e.g. the build host is a VM behind NAT), or a firewall in between. Proxy DHCP needs UDP 67 and 4011, TFTP UDP 69 |
| dnsmasq: `failed to send packet: Network is unreachable`, the firmware gets no boot file | a configuration with both `bind-interfaces` and `tftp-single-port` (older `safespace-netboot`, or a snippet in `/etc/safespace/dnsmasq.d/`): update the server (`sudo server/setup.sh`), remove `tftp-single-port` from the snippets |
| dnsmasq: `error 8 User aborted the transfer` | harmless if a `sent …` follows: UEFI PXE asks for the file size first (`tsize`) and aborts on purpose. Without a second request the firmware refused the file (too large for it) |
| the client fetches the old boot file after a change | `safespace-dhcp` still runs with the old settings: `sudo systemctl restart safespace-dhcp` (it regenerates its configuration from `server.conf`) |
| the server serves a broken release | `safespace-netboot status` / `journalctl -u safespace-netboot-verify` say which check failed; the server repairs nothing: release again from the build host |
| a new release is not checked | `safespace-netboot-verify.path` not active (`systemctl status safespace-netboot-verify.path`), or the upload did not finish (`release.sh` writes `release` last); check by hand: `sudo safespace-netboot verify` |
| `release.sh`: rsync `Permission denied` | the upload key is not on the server (`server/setup.sh --upload-key …`), or `~/.ssh/config` does not use it for that host |
| a machine reboots once during the boot after a release | expected: it loaded the old `boot.efi`, the server then had the new release (`netroot: … holds another release`) |
| a UKI over PXE: downloaded completely, then back to PXE or stuck after `NBP file …` | too large for this firmware's network boot (T450s: 82 MiB works, 112 MiB fails): check the size `mkosi.postoutput` prints, keep the network UKI below the limit ([Size of the network UKI](#size-of-the-network-uki)) |
| on a machine with Intel AMT (vPro, e.g. Intel I218-LM/I219-LM): nothing loaded over PXE runs, it reboots or hangs | disable Intel AMT in the BIOS ([Case found](#case-found-thinkpad-t450s-bios-jbet73ww)) |
| files arrive completely, then reboot / hang / back to the boot menu, even for small images | the firmware cannot start a network-loaded image (ThinkPad T450s with AMT on): disable AMT, or use the usb variant |
| a VM (OVMF) shows `Start PXE over IPv4` before HTTP boot | OVMF tries its PXE entries first; switch them off with fw_cfg `opt/org.tianocore/IPv4PXESupport=n` / `IPv6PXESupport=n` ([README, "A netbooting VM"](README.md#a-netbooting-vm-qemu-libvirt--virt-manager)) |
| a VM: `netroot: download … failed`, `Could not resolve host` | the VM's virtual network resolves through the VM host's resolver, which does not know the name in `NETROOT_URL`: put the IP (or the IP as a second URL) into `netboot.conf` and rebuild |
| boot stops in the initrd emergency shell | `journalctl -b -g netroot`, then `ip a`, `curl -I <url>/root-<name>.img` from the shell |
| host key warnings on every ssh login | expected: `/var` is RAM, so ssh host keys are new on every boot (README, "Open decisions") |

## Known limits

- **x86-64 UEFI only** (see [Scope](#scope-x86-64-uefi-only)): no legacy BIOS/CSM, no IA32
  UEFI, no other architecture.
- The URL is part of the signed command line: **moving the server means rebuilding**
  (or keeping the old address reachable). Use an address you can keep, and give a second
  URL in `NETROOT_URL` if you want a fallback server.
- Host names in the URLs are resolved with the DNS servers from the DHCP answer (in the
  initrd through systemd-networkd, see
  [A host name instead of an IP address](#a-host-name-instead-of-an-ip-address)); an IP
  address needs no DNS at all.
- The download is ~2 GiB per machine and boot. Over a 1 Gbit/s link that is ~20 s, over
  100 Mbit/s ~3 min. Many machines booting at once need the bandwidth on the server.
- TFTP for the UKI is a fallback, not a plan: ~100 MiB over TFTP takes minutes.
- One release per server: every machine of a server boots the same build; machine kinds
  differ by the combination they select (`safespace-select`), all from the same release. A server only serves the newest release, but an old signed UKI or usb stick
  still boots on a sealed machine wherever someone kept a copy (and a server with its
  release).
- Real hardware: a ThinkPad T450s (no HTTP boot) network-boots over PXE/TFTP only with
  Intel AMT disabled and a UKI that is not much larger than the current 82 MiB (see
  [Case found](#case-found-thinkpad-t450s-bios-jbet73ww)); with AMT on it boots from a
  stick. UEFI HTTP boot is tested end to end in QEMU and libvirt (OVMF, no disk):
  DHCP → signed UKI over HTTP → DHCP in the initrd → `root-<name>.verity` and `root-<name>.img` over
  HTTP → dm-verity against the signed root hash → login. Real firmware differs in how it
  offers HTTP boot and how large a boot file it accepts.
