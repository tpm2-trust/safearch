# Netboot: the `network` variant on a fresh server

The `network` variant of safespace-arch boots over the network instead of from a
stick: the firmware downloads the signed UKI (kernel + initrd + signed command line),
and the initrd downloads the read-only root image and its dm-verity hash tree into RAM.
The client writes nothing, anywhere — it has no boot medium at all.

**The whole path, for an x86-64 UEFI machine:**

1. on the build host: `sudo ./build.sh network --groups …` — [Build and release](#build-and-release)
2. on the build host: `./release.sh network --push safespace@SERVER` — the same section;
   the server verifies the release and switches its channel
3. once on the server: `sudo server/setup.sh …` (nginx, import service, optional
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
  1. DHCP: "where do I boot from?"  ───────────▶ DHCP: http://10.0.0.1/safespace/network/current/boot.efi
  2. HTTP GET /safespace/network/current/boot.efi ▶ nginx
     firmware verifies the signature against db
  3. UKI starts: kernel + initrd, command line fixed at build time
     (roothash=…, safespace.netroot=http://10.0.0.1/safespace/network/20261016-1830/)
  4. initrd: DHCP, then
     HTTP GET /safespace/network/20261016-1830/root.verity ──▶ nginx
     HTTP GET /safespace/network/20261016-1830/root.img    ──▶ nginx   (into a tmpfs)
  5. veritysetup open … roothash=…  → /dev/mapper/root
  6. root mounted read-only, /var is a tmpfs, machine is independent of the
     server from here on
```

**The machine needs nothing local for this.** There is no boot medium, no bootloader and no
file on a disk: UEFI firmware has its own network stack. Put the network device in the boot
order (or pick it from the boot menu), and the firmware does DHCP itself, takes the boot file
from the DHCP answer, downloads it into memory and starts it. All that is needed from the
machine is a NIC the firmware supports and "network boot" enabled; everything else is the
server's answer. A machine whose firmware cannot do that at all is the only case where a small
local boot medium is needed — see
[the netstick](#machines-that-cannot-network-boot-the-uki-the-netstick).

**Everything the client trusts is inside the signed UKI**, nothing comes from the
server unverified:

| What | Where it comes from | If the server lies |
|---|---|---|
| kernel, initrd, command line | the UKI, signed with your sbctl `db` key, checked by the firmware | firmware refuses to start it |
| which URL to load root from | `safespace.netroot=` on the signed command line | cannot be changed |
| root filesystem | `root.img`, checked against `roothash=` from the signed command line | `veritysetup` refuses to open it, every later block is checked by dm-verity (`--panic-on-corruption`) |

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
| `./build.sh network` | build host | builds the image | **yes** |
| `./release.sh network` | build host | the **release step**: turns mkosi's output into the files the firmware and the initrd ask for (`boot.efi`, `root.img`, `root.verity`), checks them, pushes them to the distribution servers | **yes** |
| `server/setup.sh` | distribution server | nginx, the import service, optionally dnsmasq (`safespace-dhcp`) | **yes**, once per server |
| `./test-vm.sh --netboot` | build host | a rehearsal in QEMU before you touch hardware | no, optional |
| `./netstick.sh` | build host | a loader-only USB stick for machines whose firmware cannot network-boot the UKI ([netstick](#machines-that-cannot-network-boot-the-uki-the-netstick)) | only for such machines |

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
  (`usbcore.authorized_default=0`), and unlike the usb variant there is no initrd step
  that authorizes anything.
- **RAM for the root image plus the system.** `root.img` lives in a tmpfs for as long
  as the machine runs (erofs, decompressed on read), so budget
  `size of root.img (~2 GiB) + 2 GiB`, i.e. 8 GiB to be comfortable. The initrd
  checks `MemAvailable` before downloading and says so if it is not enough.
- **Your `db` certificate enrolled**, if Secure Boot is to be enforced — see
  [Secure Boot on the clients](#secure-boot-on-the-clients).
- A data disk labelled `safespace-docker` on SATA/NVMe if Docker is used (as with the
  usb variant; see README).

## Build and release

Once per build host, as for the usb variant: `users.conf` and `safespace.env`. The public
Secure Boot keys for `safespace-seal` are exported by `build.sh` on every build. Then set
the URL of the distribution servers (`SERVER_URL` of their `server.conf` + `/network/`):

```sh
cp netboot.conf.example netboot.conf     # NETROOT_URL=http://10.0.0.1/safespace/network/
sudo ./build.sh network --groups base    # -> mkosi.output/safespace-arch-network_<version>.*
./release.sh network --push safespace@10.0.0.1
```

`build.sh` appends the build version to `NETROOT_URL` and signs it into the UKI, so
**a UKI always loads the root image of exactly its own build**. The layout in the share of a
distribution server (`/srv/safespace/share/`, served as `http://10.0.0.1/safespace/`):

```
/srv/safespace/share/
├── network/
│   ├── 20261016-1830/
│   │   ├── boot.efi       the signed UKI (what the firmware downloads)
│   │   ├── root.img       erofs root partition, ~2 GiB (dm-verity data)
│   │   ├── root.verity    its dm-verity hash tree, ~17 MiB
│   │   ├── roothash, cmdline, release, manifest.json, SHA256SUMS
│   ├── 20261016-2015/…
│   ├── current -> 20261016-2015      a channel: only the DHCP boot file points here
│   └── desktop -> 20261016-1830      another channel
├── usb/<version>/image.raw.zst …, usb/current -> …
└── .pending/                          uploads waiting for the import (never served)
```

`release.sh` refuses to release artifacts that do not belong together: it checks the UKI's
signature against the exported `db.pem`, compares the root hash on the UKI's signed command
line with the build's, and runs `veritysetup verify` over the whole root image — so a bad set
is caught on the build host instead of on 50 machines. Every distribution server repeats
exactly these checks (`lib/verify.sh`) before it switches a channel to the release.

## The distribution server

A distribution server needs two things for network boot: an HTTP server for the files and a
DHCP answer that names the boot file. `server/setup.sh` sets up the first (nginx on the
share, plus the import service that verifies uploads), and optionally the second
(`safespace-dhcp`, dnsmasq: `DHCP_MODE=proxy` or `dhcp`). It stores nothing secret:
everything in the share is public and signed; the only key it holds is the public `db.pem`.
Commands, settings and services: README.md,
["Distribution server"](README.md#distribution-server).

### 1. HTTP

nginx serves the share read-only: `/etc/nginx/conf.d/safespace.conf` (from
`server/nginx/safespace.conf`), GET/HEAD only, no listing, no hidden files. Check from another
machine:

```sh
curl -I http://10.0.0.1/safespace/network/current/boot.efi    # 200 OK and a Content-Length
```

`Content-Length` matters: the initrd uses it to size the tmpfs and to check that there
is enough RAM before it starts downloading.

### 2. Keep a few versions

`KEEP=3` in `server.conf`: two or three versions (~2 GiB each) so you can roll back
(`safespace-netboot rollback`); the import prunes older ones, never one a channel points at.

### 3. DHCP and the boot file

Only two things have to reach the machine, whatever DHCP server you run:

| DHCP option | HTTP boot (the fast path) | PXE/TFTP fallback |
|---|---|---|
| 60, vendor class identifier | `HTTPClient` | — |
| 67, boot file name | `http://10.0.0.1/safespace/network/current/boot.efi` (full URL) | `network/current/boot.efi` (path under the TFTP root = the share) |
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
dhcp-boot=tag:httpclient,http://10.0.0.1/safespace/network/current/boot.efi
# Fallback for UEFI machines without HTTP boot: PXE over TFTP. client-arch 7
# and 9 are x86-64 UEFI; legacy BIOS (0) and IA32 UEFI (6) get no answer.
dhcp-boot=tag:efi64,network/current/boot.efi
enable-tftp
tftp-root=/srv/safespace/share
# all of TFTP on port 69, so a firewall only needs UDP 69 (and 67/4011 for DHCP)
tftp-single-port
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
pxe-service=tag:efi64,x86-64_EFI,"safespace netboot",network/current/boot.efi
```

(plus the interface, `dhcp-match`, TFTP and log lines as above). Proxy mode reliably drives
the **TFTP** path only: UEFI HTTP boot wants the URL and the vendor class from the DHCP
server that owns the network.

```sh
journalctl -u safespace-dhcp -f        # watch a client boot
```

Site additions (per-machine channels, extra options) go into
`/etc/safespace/dnsmasq.d/*.conf`; see README.md,
["Channels in DHCP"](README.md#channels-in-dhcp).

#### ISC dhcpd (`dhcpd.conf`)

```
option arch code 93 = unsigned integer 16;

# UEFI HTTP boot: answer with the vendor class and the full URL.
class "safespace-http" {
    match if substring(option vendor-class-identifier, 0, 10) = "HTTPClient";
    option vendor-class-identifier "HTTPClient";
    filename "http://10.0.0.1/safespace/network/current/boot.efi";
}

# UEFI PXE (x86-64): a path under the TFTP root plus the TFTP server.
class "safespace-pxe" {
    match if option arch = 7 or option arch = 9;
    filename "network/current/boot.efi";
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
    "boot-file-name": "http://10.0.0.1/safespace/network/current/boot.efi",
    "option-data": [
      { "name": "vendor-class-identifier", "data": "HTTPClient" }
    ]
  },
  {
    "name": "safespace-pxe",
    "test": "option[93].hex == 0x0007 or option[93].hex == 0x0009",
    "next-server": "10.0.0.1",
    "boot-file-name": "network/current/boot.efi"
  }
]
```

#### Routers, firewalls and Windows Server

- **OPNsense / pfSense:** *Services → DHCPv4 → \[interface\]*. For the PXE path use
  "Network booting": next-server `10.0.0.1`, filename `network/current/boot.efi`. For
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
netroot: fetching the root image from http://10.0.0.1/safespace/20261016-1830
netroot: root.img 2013 MiB + root.verity 16 MiB, 15822 MiB RAM free
netroot: got root.verity: 16 MiB in 1s (16 MiB/s)
netroot: got root.img: 2013 MiB in 19s (105 MiB/s)
netroot: root opened as /dev/mapper/root (/dev/loop0 = /run/netroot/root.img), verified against roothash=ea0e130f2f63...
```

**4. Check it on the machine** (ssh in with a key from `users.conf`, or at the console):

```sh
journalctl -b -g netroot      # the lines above, from this boot
findmnt /                     # /dev/mapper/root, erofs, ro
veritysetup status root       # verity device, read-only, the root hash from the UKI
df -h /run/netroot            # the root image in RAM (tmpfs), as large as root.img
bootctl status                # "Secure Boot: enabled" once the machine is sealed
cat /proc/cmdline             # the signed command line incl. safespace.netroot=
```

On the server side, one boot shows up as three requests in nginx's access log:
`boot.efi`, `root.verity`, `root.img`.

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
sudo ./build.sh network --url http://192.168.1.10/safespace/network/
./release.sh network --push safespace@localhost
journalctl -u safespace-netboot-import      # verified, network/current -> <version>

# 3. on the test machine: one-time boot menu -> "UEFI PXEv4 ..."
journalctl -u safespace-dhcp -f
```

Afterwards `sudo systemctl disable --now safespace-dhcp`, or
`DHCP_MODE=off` and rerun `server/setup.sh`.

A firewall between the machine and the build host has to let through UDP 67 and 4011 (proxy
DHCP) and UDP 69 (TFTP, all of it with `tftp-single-port`). Proxy DHCP only works on the
machine's own L2 segment: a build host in a VM behind NAT never sees the broadcasts.

In this mode the ~82 MiB UKI comes over TFTP, which takes about a minute; the ~2 GiB root
image still comes over HTTP at full speed. For the fast path configure the real DHCP server
(options 60/67), or give the test machines their own VLAN with `DHCP_MODE=dhcp`
([Case A](#3-dhcp-and-the-boot-file)).

## Secure Boot on the clients

The firmware checks a downloaded boot file exactly like one from an ESP: the UKI's
signature must match a certificate in `db`. So nothing special is needed for netboot —
but the `db` certificate has to be on the machine. Three ways, all using the keys that
`build.sh` exports into every image (`secureboot-export.sh`):

1. **Seal from the netboot itself** (no stick needed). Firmware setup: *Reset to Setup
   Mode* / *Clear Secure Boot keys*. With no keys enrolled, Secure Boot cannot be
   enforced, so the machine netboots. Then on the machine:
   ```sh
   sudo safespace-seal          # enrolls db, KEK, PK (see README, "Sealing")
   ```
   Reboot, check that Secure Boot is on, set a firmware password. From now on the
   machine only boots UKIs signed with your `db` key — including the one it downloads.
2. **Seal from a usb stick**: `sudo ./build.sh usb`, `sudo ./burn.sh /dev/sdX`, boot it
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
  NETROOT_URL="http://boot.example.internal/safespace/network/ http://10.0.0.1/safespace/network/"
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
sudo ./build.sh network --groups base,remotedesktop -f

# 3. release: every server verifies it and switches the channel
./release.sh network --channel current --prune 3
```

A server writes nothing into the channel until the whole release is there and verified;
only then does it move the symlink, so machines keep booting the old version until the
moment it is switched. Because the UKI knows its own version directory, a machine that
downloads `boot.efi` during the switch still gets the matching root image.

**Rolling back**, on the server: `sudo safespace-netboot rollback` (the verified release
before the channel's current one), or `sudo safespace-netboot activate <version>`.

Machines take the new (or old) version on their next boot; a running machine is not
affected, it has everything in RAM.

**Clean up:** the import keeps `KEEP` releases per variant (never one a channel points
at). An old UKI stays bootable as long as its directory exists, and that is also what makes
the rollback work — keep at least the previous version.

**Disk space:** ~2 GiB per version on every server, and on the build host the same again
in `mkosi.output/` plus the staged release in `mkosi.release/` (`release.sh --prune N`).
`sudo mkosi clean` removes old outputs (`sudo mkosi -ff clean` also the caches).

## Optional: rehearse it in QEMU first

This is only a rehearsal on the build host — it is not needed for, and says nothing about,
a particular piece of hardware. It is useful to check the artifacts, the initrd and the
Secure Boot signature before carrying anything into a server room.

A published build, from the real server, by pure UEFI HTTP boot (no local server, no
special build; the VM reaches the server through QEMU's NAT and resolves names through the
host):

```sh
./test-vm.sh --netboot --url http://10.0.0.1/safespace/network/current/boot.efi --ssh 2222
./test-vm.sh --netboot --url http://10.0.0.1/safespace/network/current/boot.efi --setup-mode --ssh 2222   # then safespace-seal inside, then --sealed
```

A netbooting VM of its own (plain QEMU, or a persistent libvirt machine for virt-manager,
with PXE switched off in OVMF so it goes straight to HTTP boot):
[README, "A netbooting VM"](README.md#a-netbooting-vm-qemu-libvirt--virt-manager).

Or a self-contained lab on the build host:

```sh
# built for the VM: QEMU's user network is the host at 10.0.2.2, and the
# console= part puts the kernel and netroot messages into mkosi.test/serial.log
sudo ./build.sh network --url http://10.0.2.2:8000/ \
     --kernel-command-line console=ttyS0,115200
./release.sh network                   # stage only: mkosi.release/network/current
./test-vm.sh --netboot                 # add --ssh 2222 to log in
```

The VM gets no disk at all. QEMU's user network is the DHCP server, `test-vm.sh --netboot`
serves `mkosi.release/network/` over HTTP on `127.0.0.1:8000` (a symlink farm, so the path inside
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
netroot: fetching the root image from http://10.0.2.2:8000/20261016-1830
netroot: got root.verity: 15 MiB in 1s
netroot: got root.img: 1956 MiB in 15s (130 MiB/s)
netroot: root opened as /dev/mapper/root (/dev/loop0 = /run/netroot/root.img)
[  OK  ] Mounted /sysroot.
…
safespace login:
```

After QEMU exits, `test-vm.sh` prints which steps of that chain it found in the log, and
which files the VM asked the HTTP server for. With `--ssh 2222` you can log in and look
around: `journalctl -b -g netroot`, `findmnt /`, `df -h /run/netroot`,
`veritysetup status root`.

## Machines that cannot network-boot the UKI: the netstick

Still UEFI, but the firmware has no usable network boot — no HTTP boot or PXE at all, or,
as on the ThinkPad T450s with Intel AMT enabled (below), a network boot that cannot start
any image it loaded.
Such a machine boots a **netstick**: a small USB stick that holds only the loader —
signed systemd-boot and the signed network UKI, the same layout as the usb variant's ESP.
Everything else still comes from the netboot server: the initrd gets its address from the
normal DHCP server (no boot options, no proxy DHCP, no TFTP needed) and loads
`root.img`/`root.verity` over HTTP, checked against the root hash in the signed UKI.

```sh
sudo ./build.sh network                       # add --debug for ethtool, dmidecode, kexec-tools, ...
./release.sh network --push safespace@10.0.0.1     # the stick needs a released version
sudo ./netstick.sh                                  # -> mkosi.output/safespace-arch-netstick_<version>.raw
sudo dd if=mkosi.output/safespace-arch-netstick_<version>.raw of=/dev/sdX bs=4M conv=fsync oflag=direct status=progress
sudo ./diagnose.sh /dev/sdX                   # ESP, signatures, and whether the server serves its root
```

(`sudo ./burn.sh --netstick /dev/sdX` does the `dd` with the usual safety checks.)

- `netstick.sh` takes the UKI from the **released** tree (default `mkosi.release/network/current`,
  `--tree` for a server's `share/network`, `--version` for another one), i.e. after `release.sh` has verified it against its
  root image, and refuses a UKI whose netroot URL does not end in that version.
- It signs systemd-boot with the key and sign tool mkosi uses (`mkosi --json summary`,
  so `mkosi.local.conf` overrides count) and checks that systemd-boot and the UKI have the
  same signer. Secure Boot stays intact: nothing unsigned is on the stick.
- Image: GPT with one ESP (FAT32, 512-byte sectors), `\EFI\BOOT\BOOTX64.EFI` and
  `\EFI\Linux\safespace-arch-network_<version>.efi`, no `loader.conf`: systemd-boot starts
  the UKI immediately and writes nothing to the stick.
- **The stick is tied to its version**: the UKI loads `<base>/<version>/`, so it boots as
  long as the server keeps that version, and a new release needs a new stick.
- The stick is only read while the firmware loads the UKI; afterwards the kernel ignores
  it (`usbcore.authorized_default=0`), it can even be pulled.

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
that (the intended path, also without iPXE). The netstick stays the fallback for a
machine where AMT has to stay on.

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

The network initrd only has to bring up the NIC, fetch and verify the root image and
mount it, so the initrd (of both variants, to keep them aligned) trims what mkosi's default
initrd brings along:

- **Drivers** (`KernelInitrdModules=`): an explicit list instead of mkosi's default set —
  dm-verity, loop, erofs, crypto, virtio_net for QEMU (`mkosi.conf`, both variants), and
  for the network variant the client NIC families (`mkosi.profiles/network/mkosi.conf`) (Intel e1000/e1000e/igb/igc/ixgbe, Realtek, Broadcom
  tg3/b44, Marvell sky2, Atheros, Aquantia, AMD pcnet32) with PHY/MDIO helpers. No
  server NICs (Mellanox, QLogic, Chelsio, Solarflare, Intel i40e/ice, Broadcom bnx2x …)
  and their firmware, no storage or filesystem drivers. To netboot a machine with
  another NIC, add its driver there.
- **Programs** (`mkosi.initrd.conf/mkosi.conf`, `RemoveFiles=`, both variants):
  filesystem tools (btrfs, xfs, ext4, vfat), systemd tools without a job in the initrd,
  glibc's charset converters, the gcc sanitizer runtimes, certificate CLIs, and
  terminal/timezone/keymap data beyond the console defaults.

The usb variant uses the same trimmed initrd with its own boot-path drivers (USB host
controllers, USB storage, MMC, card readers) instead of the NICs; it would not need the
size, but both variants stay aligned.

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
| firmware downloads, then "Access Denied" / nothing | Secure Boot is enforced but `db` does not have your certificate: seal the machine (see above). `release.sh` and the server's import print the signer |
| firmware resets or hangs on the download | the UKI may be too large for this firmware: shrink it (`KernelInitrdModules=` in `mkosi.profiles/network/mkosi.conf`, e.g. only `/drivers/net/ethernet/intel/`) and rebuild; or use a [netstick](#machines-that-cannot-network-boot-the-uki-the-netstick) |
| `netroot: no link reported as online` | NIC driver missing in the initrd (add it to `KernelInitrdModules=`), no DHCP on that port, or the NIC is on USB (not supported) |
| `netroot: not enough RAM` | the machine cannot hold the root image; more RAM, or a smaller image (fewer packages) |
| `netroot: download … failed` | nginx not running, wrong path, or firewall; the message contains curl's own error |
| `netroot: dm-verity refused the image` | `root.img`/`root.verity` in that directory are not the ones the UKI was signed for: release it again with `release.sh` (it and the server's import check this before serving) |
| the screen says `Start PXE over IPv4`, `Station IP address …`, but nginx sees nothing | that is the firmware's **PXE** client, not HTTP boot: it wants a TFTP file name and a TFTP server, an HTTP URL in option 67 fails. Enable HTTP boot and pick the "HTTPv4" entry, or serve the UKI over TFTP (dnsmasq `pxe-service` / proxy DHCP, [Quick one-off test](#quick-one-off-test-on-an-existing-lan)) |
| proxy DHCP (dnsmasq) logs nothing when the client boots | the broadcasts do not reach dnsmasq: another L2 segment (e.g. the build host is a VM behind NAT), or a firewall in between. Proxy DHCP needs UDP 67 and 4011, TFTP UDP 69 (with `tftp-single-port` nothing else) |
| dnsmasq: `error 8 User aborted the transfer` | harmless if a `sent …` follows: UEFI PXE asks for the file size first (`tsize`) and aborts on purpose. Without a second request the firmware refused the file (too large for it) |
| the client fetches the old boot file after a change | `safespace-dhcp` still runs with the old settings: `sudo systemctl restart safespace-dhcp` (it regenerates its configuration from `server.conf`) |
| a release never shows up on the server | `journalctl -u safespace-netboot-import`: `REJECTED …` says which check failed (the release is deleted, upload it again); nothing at all: the upload did not finish (`release.sh` sends the `.pending/` marker last), or `safespace-netboot-import.path` is not active |
| `release.sh`: rsync `Permission denied` / `skipping non-regular file` | the upload key is not on the server (`server/setup.sh --upload-key …`), or the version already exists there: released versions cannot be replaced, build a new one |
| a UKI over PXE: downloaded completely, then back to PXE or stuck after `NBP file …` | too large for this firmware's network boot (T450s: 82 MiB works, 112 MiB fails): check the size `mkosi.postoutput` prints, keep the network UKI below the limit ([Size of the network UKI](#size-of-the-network-uki)) |
| on a machine with Intel AMT (vPro, e.g. Intel I218-LM/I219-LM): nothing loaded over PXE runs, it reboots or hangs | disable Intel AMT in the BIOS ([Case found](#case-found-thinkpad-t450s-bios-jbet73ww)) |
| files arrive completely, then reboot / hang / back to the boot menu, even for small images | the firmware cannot start a network-loaded image (ThinkPad T450s): use a [netstick](#machines-that-cannot-network-boot-the-uki-the-netstick) |
| a VM (OVMF) shows `Start PXE over IPv4` before HTTP boot | OVMF tries its PXE entries first; switch them off with fw_cfg `opt/org.tianocore/IPv4PXESupport=n` / `IPv6PXESupport=n` ([README, "A netbooting VM"](README.md#a-netbooting-vm-qemu-libvirt--virt-manager)) |
| a VM: `netroot: download … failed`, `Could not resolve host` | the VM's virtual network resolves through the VM host's resolver, which does not know the name in `NETROOT_URL`: put the IP (or the IP as a second URL) into `netboot.conf` and rebuild |
| boot stops in the initrd emergency shell | `journalctl -b -g netroot`, then `ip a`, `curl -I <url>/root.img` from the shell |
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
- An old version stays bootable as long as it is on the server (as with old signed
  sticks: whoever can reach the server can boot an old build, which is why only the
  ones you still want should be there).
- Real hardware: a ThinkPad T450s (no HTTP boot) network-boots over PXE/TFTP only with
  Intel AMT disabled and a UKI that is not much larger than the current 82 MiB (see
  [Case found](#case-found-thinkpad-t450s-bios-jbet73ww)); with AMT on it needs a
  netstick. UEFI HTTP boot is tested end to end in QEMU and libvirt (OVMF, no disk):
  DHCP → signed UKI over HTTP → DHCP in the initrd → `root.verity` and `root.img` over
  HTTP → dm-verity against the signed root hash → login. Real firmware differs in how it
  offers HTTP boot and how large a boot file it accepts.
