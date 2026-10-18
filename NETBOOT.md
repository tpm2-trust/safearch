# Netboot: the `network` variant on a fresh server

The `network` variant of safespace-arch boots over the network instead of from a
stick: the firmware downloads the signed UKI (kernel + initrd + signed command line),
and the initrd downloads the read-only root image and its dm-verity hash tree into RAM.
The client writes nothing, anywhere — it has no boot medium at all.

**The whole path, for an x86-64 UEFI machine:**

1. on the build host: `sudo ./build.sh network` — [Build and publish](#build-and-publish)
2. on the build host: `./netboot-export.sh --rsync root@SERVER:/srv/netboot/safespace` —
   the same section; this is what names the files the way the machine asks for them
3. once on the server: nginx and dnsmasq — [The server from scratch](#the-server-from-scratch)
4. on the machine: switch network boot on in the firmware and boot it —
   [Boot a real machine](#boot-a-real-machine)

Nothing else is needed; `./test-vm.sh --netboot` is only an optional rehearsal in QEMU.

This file is the reference and uses a generic server at `10.0.0.1`. The concrete values of
this installation — the name `arch.boot.internal`, the tree `/srv/netboot/safespace` and the
commands in order — are in README.md,
["Network boot: build and provide"](README.md#network-boot-build-and-provide).

```
  machine (UEFI, Secure Boot on)                 server
  ──────────────────────────────                 ──────
  1. DHCP: "where do I boot from?"  ───────────▶ dnsmasq: http://10.0.0.1/safespace/current/boot.efi
  2. HTTP GET /safespace/current/boot.efi ─────▶ nginx
     firmware verifies the signature against db
  3. UKI starts: kernel + initrd, command line fixed at build time
     (roothash=…, safespace.netroot=http://10.0.0.1/safespace/20261016-1830/)
  4. initrd: DHCP, then
     HTTP GET /safespace/20261016-1830/root.verity ──▶ nginx
     HTTP GET /safespace/20261016-1830/root.img    ──▶ nginx   (into a tmpfs)
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

| | What it is for | Needed for a real machine? |
|---|---|---|
| `./build.sh network` | builds the image on the build host | **yes** |
| `./netboot-export.sh` | the **publish step**: turns mkosi's output into the three files the firmware and the initrd ask for (`boot.efi`, `root.img`, `root.verity`), decompresses them, checks that they belong together, puts them in `<tree>/<version>/` and moves `current`. Optionally rsyncs to the server | **yes** (or do it by hand, see below) |
| dnsmasq + nginx on the server | the DHCP answer and the files over HTTP | **yes** |
| `./test-vm.sh --netboot` | a rehearsal of exactly that in QEMU, on your build host, before you touch hardware | no, optional |
| `./netstick.sh` | a loader-only USB stick for machines whose firmware cannot network-boot the UKI ([netstick](#machines-that-cannot-network-boot-the-uki-the-netstick)) | only for such machines |

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
  signed UKI directly. iPXE is not part of either path (it was only used to diagnose
  the T450s).
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

## Build and publish

Once per build host, as for the usb variant: `users.conf` and `safespace.env`. The public
Secure Boot keys for `safespace-seal` are exported by `build.sh` on every build.
Then set the URL of your netboot tree:

```sh
cp netboot.conf.example netboot.conf     # NETROOT_URL=http://10.0.0.1/safespace/
sudo ./build.sh network                  # -> mkosi.output/safespace-arch-network_<version>.*
./netboot-export.sh                      # stages mkosi.netboot/<version>/ + current; not yet on the server
```

`build.sh` appends the build version to `NETROOT_URL` and signs it into the UKI, so
**a UKI always loads the root image of exactly its own build**. The published layout:

```
/srv/netboot/safespace/
├── 20261016-1830/
│   ├── boot.efi       the signed UKI (what the firmware downloads)
│   ├── root.img       erofs root partition, ~2 GiB (dm-verity data)
│   ├── root.verity    its dm-verity hash tree, ~17 MiB
│   ├── roothash       the root hash, for reference
│   └── cmdline        the signed kernel command line, for reference
├── 20261016-2015/…
└── current -> 20261016-2015      only the DHCP boot file points here
```

`netboot-export.sh` refuses to publish artifacts that do not belong together: it
compares the root hash in the UKI's command line with the build's root hash and runs
`veritysetup verify` over the whole root image, so a bad set is caught on the build
host instead of on 50 machines. It also prints which certificate the UKI is signed
with — that is the one that has to be in `db`.

Copy the tree to the server (or let the script do it in the same run):

```sh
./netboot-export.sh --rsync root@10.0.0.1:/srv/netboot/safespace
```

**There is nothing magic in that step**: mkosi writes its artifacts under the build's own
names and compressed, while the firmware and the initrd ask for fixed names. By hand it is:

```sh
v=20261016-1830                                     # the build to publish
d=/srv/netboot/safespace/$v
install -d -m 0755 "$d"
install -m 0644 mkosi.output/safespace-arch-network_$v.efi "$d/boot.efi"
zstd -dqf mkosi.output/safespace-arch-network_$v.root.raw.zst        -o "$d/root.img"
zstd -dqf mkosi.output/safespace-arch-network_$v.root-verity.raw.zst -o "$d/root.verity"
ln -sfn "$v" /srv/netboot/safespace/.current.new                     # move "current" over
mv -T /srv/netboot/safespace/.current.new /srv/netboot/safespace/current
```

The script does the same, plus the checks (root hash in the UKI against the published
images, `veritysetup verify`, the signing certificate) and the pruning of old versions.

## The server from scratch

A netboot server needs two things: a DHCP answer that names the boot file, and an
HTTP server for the files. The example below uses **dnsmasq** (DHCP, proxy-DHCP, TFTP)
and **nginx**, on a server at `10.0.0.1/24`. It stores nothing secret: everything in
the tree is public and signed.

For a first test the "server" can be the build host itself: publish into `mkosi.netboot/`,
serve that directory with `python3 -m http.server` and let the LAN's DHCP server (or a
proxy-DHCP dnsmasq) point at it — see
[Quick one-off test on an existing LAN](#quick-one-off-test-on-an-existing-lan). The
permanent setup below is the same thing with nginx and a fixed path.

```sh
# Arch
pacman -S --needed dnsmasq nginx
# Debian / Ubuntu
apt install dnsmasq nginx-light
```

### 1. The tree

```sh
install -d -m 0755 /srv/netboot/safespace
# later filled by netboot-export.sh --rsync, or by rsync/scp by hand
```

Keep two or three versions (~2 GiB each) so you can roll back; `--prune` removes
older ones.

### 2. HTTP (nginx)

`/etc/nginx/conf.d/netboot.conf` (Arch) or `/etc/nginx/sites-available/netboot`
(Debian; symlink it into `sites-enabled/` and remove the default site). Arch ships
neither `conf.d/` nor an include for it: `install -d /etc/nginx/conf.d` and add
`include conf.d/*.conf;` inside `http { }` in `nginx.conf` (the README's server
ramp-up does both). The stock `server_name localhost` block in Arch's `nginx.conf`
can stay; the block below is the `default_server`.

```nginx
server {
    listen      80 default_server;
    listen      [::]:80 default_server;
    server_name _;
    root        /srv/netboot;

    autoindex   off;
    sendfile    on;
    tcp_nopush  on;
    server_tokens off;

    # Nothing but reading the published files.
    location / {
        limit_except GET HEAD { deny all; }
    }
}
```

On Debian the Arch example needs `include /etc/nginx/sites-enabled/*;` in
`nginx.conf`, which the distribution package already has. Then:

```sh
systemctl enable --now nginx
curl -I http://10.0.0.1/safespace/current/boot.efi    # 200 OK and a Content-Length
```

`Content-Length` matters: the initrd uses it to size the tmpfs and to check that there
is enough RAM before it starts downloading.

### 3. DHCP and the boot file

Only two things have to reach the machine, whatever DHCP server you run:

| DHCP option | HTTP boot (the fast path) | PXE/TFTP fallback |
|---|---|---|
| 60, vendor class identifier | `HTTPClient` | — |
| 67, boot file name | `http://10.0.0.1/safespace/current/boot.efi` (full URL) | `safespace/current/boot.efi` (path under the TFTP root) |
| 66 / `next-server` (siaddr) | — | `10.0.0.1`, the TFTP server |

There is no third thing: no agent, no per-machine entry, no MAC list. The address the
machine gets is its normal lease.

**Send them only to the clients that asked for them.** A machine says what it is in its
request: option 60 starts with `HTTPClient:Arch:00016` and option 93 (client
architecture) is `16` for x86-64 UEFI HTTP boot, `7` or `9` for x86-64 UEFI PXE. A firmware
that starts its PXE entry and receives an HTTP URL fails with `PXE-E23`, so the two answers
must be kept apart — that is all the conditions in the examples below do. Legacy BIOS
clients (option 93 = `0`) get no answer at all: the boot file is a UEFI binary.

#### dnsmasq

**Case A — dnsmasq is the DHCP server** for this network (e.g. a dedicated boot VLAN).
`/etc/dnsmasq.d/netboot.conf`:

```ini
interface=eth0
bind-interfaces
domain-needed
bogus-priv

dhcp-range=10.0.0.100,10.0.0.200,12h
dhcp-option=option:router,10.0.0.1
dhcp-option=option:dns-server,10.0.0.1

# UEFI HTTP Boot (the normal path): the client announces itself as HTTPClient
# with architecture 00016 = x86-64 UEFI HTTP. The reply has to repeat the
# vendor class and give the full URL as the boot file.
dhcp-vendorclass=set:httpclient,HTTPClient:Arch:00016
dhcp-match=set:httpclient,option:client-arch,16
dhcp-option-force=tag:httpclient,60,HTTPClient
dhcp-boot=tag:httpclient,http://10.0.0.1/safespace/current/boot.efi

# Fallback for UEFI machines without HTTP boot: PXE over TFTP (slow, ~100 MiB).
# client-arch 7 and 9 are x86-64 UEFI; 0 (legacy BIOS) and 6 (IA32 UEFI) are
# intentionally not answered, the UKI is an x86-64 UEFI binary.
dhcp-match=set:efi64,option:client-arch,7
dhcp-match=set:efi64-bc,option:client-arch,9
dhcp-boot=tag:efi64,safespace/current/boot.efi,,10.0.0.1
dhcp-boot=tag:efi64-bc,safespace/current/boot.efi,,10.0.0.1
enable-tftp
tftp-root=/srv/netboot
# all of TFTP on port 69, so a firewall only needs UDP 69 (and 67/4011 for DHCP)
tftp-single-port

log-dhcp
```

Answering each client according to what it asked for is what keeps a machine from running
into `PXE-E23`: a firmware that starts its PXE entry would otherwise get an HTTP URL and
try to fetch it over TFTP.

**Case B — there is already a DHCP server** and you must not replace it. Run dnsmasq
in proxy mode: it only answers the boot question, the existing server keeps handing
out addresses.

```ini
interface=eth0
bind-interfaces
# Proxy only: no addresses, no DNS.
port=0
dhcp-range=10.0.0.0,proxy
pxe-service=tag:efi64,x86-64_EFI,"safespace netboot",safespace/current/boot.efi
dhcp-match=set:efi64,option:client-arch,7
dhcp-match=set:efi64,option:client-arch,9
enable-tftp
tftp-root=/srv/netboot
# all of TFTP on port 69, so a firewall only needs UDP 69 (and 67/4011 for DHCP)
tftp-single-port
log-dhcp
```

Proxy mode reliably drives the **TFTP** path only: UEFI HTTP boot wants the URL and the
vendor class from the DHCP server that owns the network.

```sh
systemctl enable --now dnsmasq
journalctl -u dnsmasq -f        # watch a client boot
```

#### ISC dhcpd (`dhcpd.conf`)

```
option arch code 93 = unsigned integer 16;

# UEFI HTTP boot: answer with the vendor class and the full URL.
class "safespace-http" {
    match if substring(option vendor-class-identifier, 0, 10) = "HTTPClient";
    option vendor-class-identifier "HTTPClient";
    filename "http://10.0.0.1/safespace/current/boot.efi";
}

# UEFI PXE (x86-64): a path under the TFTP root plus the TFTP server.
class "safespace-pxe" {
    match if option arch = 7 or option arch = 9;
    filename "safespace/current/boot.efi";
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
    "boot-file-name": "http://10.0.0.1/safespace/current/boot.efi",
    "option-data": [
      { "name": "vendor-class-identifier", "data": "HTTPClient" }
    ]
  },
  {
    "name": "safespace-pxe",
    "test": "option[93].hex == 0x0007 or option[93].hex == 0x0009",
    "next-server": "10.0.0.1",
    "boot-file-name": "safespace/current/boot.efi"
  }
]
```

#### Routers, firewalls and Windows Server

- **OPNsense / pfSense:** *Services → DHCPv4 → \[interface\]*. For the PXE path use
  "Network booting": next-server `10.0.0.1`, filename `safespace/current/boot.efi`. For
  HTTP boot add the two options under "Additional BOOTP/DHCP Options": number 60, type
  string, value `HTTPClient`, and number 67, type string, value with the full URL.
- **Windows Server DHCP:** option 067 (Bootfile Name) takes the URL; option 060 has to be
  defined once (`netsh dhcp server add optiondef 60 HTTPClient STRING 0`) and then set to
  `HTTPClient`. Put both into a DHCP *policy* whose condition is the vendor class
  `HTTPClient*`, so other clients are unaffected.
- **Consumer routers (Fritz!Box and friends)** usually cannot set options 60/67 at all. Use
  the proxy-DHCP recipe in
  [Quick one-off test on an existing LAN](#quick-one-off-test-on-an-existing-lan): it adds
  only the boot answer and leaves the router's DHCP alone.

### 4. Firewall

Only three ports are needed, TFTP only if you use the PXE fallback:

```nft
tcp dport 80 accept             # HTTP: UKI and root images
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

To try a real machine before setting up a server: the only thing the LAN's own DHCP server
will not tell the machine is where to boot from, and dnsmasq can add just that answer
without handing out addresses ("proxy DHCP"), so the existing DHCP server is untouched.
Everything runs on the build host; `dnsmasq` is the only extra package (`pacman -S dnsmasq`).
This works for **PXE only**: dnsmasq in proxy mode answers only clients that announce
`PXEClient`, so UEFI HTTP boot (options 60/67) always needs the DHCP server that hands out
the address. `./pxe-proxy.sh BOOTFILE` runs step 3 below with the values of this host.

```sh
# 1. build for the build host's own address (a port above 1024 needs no root
#    for the file server), and publish into the local tree
sudo ./build.sh network --url http://192.168.1.10:8000/
./netboot-export.sh

# 2. serve the root images (mkosi.netboot/ holds <version>/ and current/)
(cd mkosi.netboot && python3 -m http.server 8000) &

# 3. answer only the boot question on the LAN, and hand out the UKI over TFTP
sudo dnsmasq -d --port=0 --dhcp-range=192.168.1.0,proxy --log-dhcp \
     --dhcp-match=set:efi64,option:client-arch,7 \
     --dhcp-match=set:efi64,option:client-arch,9 \
     '--pxe-service=tag:efi64,x86-64_EFI,safespace netboot,current/boot.efi' \
     --enable-tftp --tftp-root="$PWD/mkosi.netboot" --tftp-single-port

# 4. on the test machine: one-time boot menu -> "UEFI PXEv4 ..."
```

`./pxe-proxy.sh BOOTFILE` runs step 3 for you against `/srv/netboot` (`--root` for another
tree), with interface and subnet taken from the default route, and logs to
`mkosi.test/dnsmasq.log`, e.g. `sudo ./pxe-proxy.sh safespace/current/boot.efi`.

Use your own addresses: `192.168.1.10` is the build host, `192.168.1.0` the LAN that the
machine gets its address from. dnsmasq stays in the foreground and logs every DHCP and TFTP
request, which is exactly what you want to watch. A firewall between the machine and the build host has
to let through UDP 67 and 4011 (proxy DHCP) and UDP 69 (TFTP, all of it with
`--tftp-single-port`). Proxy DHCP only works on the machine's own L2 segment: a build host
in a VM behind NAT never sees the broadcasts.

In this mode the ~100 MiB UKI comes over TFTP, which takes a few minutes; the ~2 GiB root
image still comes over HTTP at full speed. Proxy DHCP cannot reliably drive UEFI **HTTP**
boot (the firmware wants the URL and the `HTTPClient` vendor class from the DHCP server that
owns the network), so for the fast path configure the real DHCP server, or give the test
machines their own VLAN with dnsmasq as in [Case A](#3-dhcp-and-the-boot-file).

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
- `netboot-export.sh` prints the certificate the UKI is signed with, and warns if it is
  not the `db.pem` shipped in the image (a sealed machine would refuse that UKI).
- Rotating keys means: new keys in sbctl, rebuild (the build exports them), publish, and re-seal the
  machines (the enrollment files carry a newer timestamp, so they replace the old ones).

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

Everything that changes the image — packages, users, `mkosi.extra/`, a new package
snapshot — needs a rebuild and a new publish. The version (build timestamp) is part of
every file name and of the URL inside the UKI, so builds never overwrite each other.

```sh
# 1. change what you want, e.g.
./update-snapshot.sh                 # newest Arch Linux Archive day (repos.conf)
vim users.conf mkosi.conf            # users, packages, …
./fetch-images.sh                    # shipped Docker images

# 2. build (-f also rebuilds unchanged packages, -ff reinstalls everything)
sudo ./build.sh network -f

# 3. publish and switch the boot file over
./netboot-export.sh --rsync root@10.0.0.1:/srv/netboot/safespace

# 4. keep the last three versions on the build host
./netboot-export.sh --prune 3
```

Step 3 writes the new version directory first and only then moves the `current`
symlink, so machines keep booting the old version until the moment it is switched.
Because the UKI knows its own version directory, a machine that downloads `boot.efi`
during the switch still gets the matching root image.

**Rolling back** is moving the symlink back — on the server:

```sh
cd /srv/netboot/safespace
ln -sfn 20261016-1830 .current.new && mv -T .current.new current
```

Machines take the new (or old) version on their next boot; a running machine is not
affected, it has everything in RAM.

**Clean up** on the server when a version is no longer needed:
`rm -rf /srv/netboot/safespace/<version>` — but note that an old UKI stays bootable as
long as its directory exists, and that is also what makes the rollback work. Keep at
least the previous version.

**Disk space:** ~2 GiB per version on the server, and on the build host the same again
in `mkosi.output/` plus the staged copy in `mkosi.netboot/`. `sudo mkosi clean` removes
old outputs (`sudo mkosi -ff clean` also the caches).

## Optional: rehearse it in QEMU first

This is only a rehearsal on the build host — it is not needed for, and says nothing about,
a particular piece of hardware. It is useful to check the artifacts, the initrd and the
Secure Boot signature before carrying anything into a server room.

A published build, from the real server, by pure UEFI HTTP boot (no local server, no
special build; the VM reaches the server through QEMU's NAT and resolves names through the
host):

```sh
./test-vm.sh --netboot --url http://10.0.0.1/safespace/current/boot.efi --ssh 2222
./test-vm.sh --netboot --url http://10.0.0.1/safespace/current/boot.efi --setup-mode --ssh 2222   # then safespace-seal inside, then --sealed
```

Or a self-contained lab on the build host:

```sh
# built for the VM: QEMU's user network is the host at 10.0.2.2, and the
# console= part puts the kernel and netroot messages into mkosi.test/serial.log
sudo ./build.sh network --url http://10.0.2.2:8000/ \
     --kernel-command-line console=ttyS0,115200
./netboot-export.sh
./test-vm.sh --netboot                 # add --ssh 2222 to log in
```

The VM gets no disk at all. QEMU's user network is the DHCP server, `test-vm.sh --netboot`
serves the netboot tree over HTTP on `127.0.0.1:8000` (a symlink farm, so the path inside
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
./netboot-export.sh --tree /srv/netboot/safespace   # or --rsync; the stick needs a published version
sudo ./netstick.sh --tree /srv/netboot/safespace    # -> mkosi.output/safespace-arch-netstick_<version>.raw
sudo dd if=mkosi.output/safespace-arch-netstick_<version>.raw of=/dev/sdX bs=4M conv=fsync oflag=direct status=progress
sudo ./diagnose.sh /dev/sdX                   # ESP, signatures, and whether the server serves its root
```

(`sudo ./burn.sh --netstick /dev/sdX` does the `dd` with the usual safety checks.)

- `netstick.sh` takes the UKI from the **published** tree (default `mkosi.netboot/current`,
  `--version` for another one), i.e. after `netboot-export.sh` has verified it against its
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

What follows is how it was found. The firmware offers only PXE (no HTTP boot entry; "UEFI Network Stack" on, the LAN boot
entry prints `Start PXE over IPv4` / `Station IP address …`). With proxy DHCP and TFTP
(see [Quick one-off test](#quick-one-off-test-on-an-existing-lan)) every file arrives
completely, but **nothing except iPXE ever runs**:

| Loaded by | Image | Result |
|---|---|---|
| firmware PXE | the UKI (112 MiB) | downloaded once completely, then nothing; another time the firmware stopped after the size probe (`tsize`) and went back to the boot menu |
| firmware PXE | systemd-boot (160 KiB), systemd-stub + kernel (17 MiB) | reboot |
| firmware PXE | EFI shell | nothing |
| firmware PXE | iPXE `snponly.efi` | **runs**, network works |
| iPXE | the UKI, a rebuilt UKI with `efi=debug earlyprintk=efi`, systemd-stub + kernel, the bare kernel (with and without initrd), systemd-boot, the EFI shell (also starting the UKI as a file from iPXE's virtual filesystem), a second iPXE | hang, not a single kernel or EFI-stub message |
| USB stick | systemd-boot → UKI | **boots** |

So it is not the images (same PE flags, alignment and sizes boot from the stick) but the
state the firmware's network boot leaves behind. With **AMT enabled**, the I218-LM is
shared with the Intel ME, and the firmware's AMT drivers (MEBx, IDE-R, Serial-over-LAN)
run their own callbacks on that NIC. Traced inside iPXE (debug builds with
markers around `LoadImage`/`StartImage`):

1. iPXE's default `ipxe.efi` and `snponly.efi` hang right after `autoexec.ipxe… not found`,
   when iPXE takes the NIC over. Visible with `DEBUG=efi_driver`: the last line is
   `EFIDRV … using driver "NIIONLY"` (iPXE prefers the NII/UNDI interface). With NII
   disabled it uses `SNPONLY`; then it hangs when it publishes its own SNP device and HII
   form back to the firmware. With those disabled too, iPXE's network works: DHCP, ping,
   the 112 MiB UKI over HTTP in about a second.
2. `LoadImage()` of any downloaded image returns fine. `StartImage()` is never reached:
   iPXE hangs in `efi_snp_release()`, which lowers the TPL back to `TPL_APPLICATION`.
   Lowering the TPL lets the firmware's pending event callbacks run, and one of them does
   not return. **Every** TPL drop hangs at that point (also `DisconnectController()`,
   which iPXE calls at the external TPL).
3. Starting the image without lowering the TPL reaches `StartImage()`, but the image does
   not run (the UEFI spec requires `StartImage()` below `TPL_CALLBACK`).
4. Leaving the firmware's network stack bound (MNP instead of SNP, or SNP opened shared
   instead of `BY_DRIVER|EXCLUSIVE`) leaves iPXE without a working network.

With AMT enabled, the firmware's own network stack, once the PXE boot has used it and the
NIC has been taken over, cannot survive a TPL drop, and loading the next image needs one.
The iPXE patches tried (NII, HII and the SNP provider off, markers in `efi_image.c`) are
not kept in this repository: they did not lead to a working boot, disabling AMT did.

Then, read from the running system (netstick, `--debug` build, Lenovo WMI settings via
`think-lmi`): BIOS 1.37 is the last release, the NIC is an Intel I218-LM (vPro/AMT) with
the ME active, `AMTControl=Enable`. With AMT disabled, the firmware's own PXE starts
systemd-boot and Linux images of 17, 48 and 80 MiB; the 112 MiB UKI is downloaded
completely but not started (or the firmware gives up after the size probe), and a
UKI-sized test image (padding instead of an initrd) behaves the same: a size limit, not
the UKI's content.

How to recognise the case on another machine: the files are delivered completely
(dnsmasq logs `sent …`, nginx `200` with the full size), yet the machine reboots, returns
to the boot menu or hangs without a single kernel message, also for small images.

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
| DHCP but no download | `journalctl -u dnsmasq -f`: does the client get option 60/67? HTTP boot needs both. `curl -I` the URL from another machine |
| firmware downloads, then "Access Denied" / nothing | Secure Boot is enforced but `db` does not have your certificate: seal the machine (see above). `netboot-export.sh` prints the signer |
| firmware resets or hangs on the download | the UKI may be too large for this firmware: shrink it (`KernelInitrdModules=` in `mkosi.profiles/network/mkosi.conf`, e.g. only `/drivers/net/ethernet/intel/`) and rebuild; or use a [netstick](#machines-that-cannot-network-boot-the-uki-the-netstick) |
| `netroot: no link reported as online` | NIC driver missing in the initrd (add it to `KernelInitrdModules=`), no DHCP on that port, or the NIC is on USB (not supported) |
| `netroot: not enough RAM` | the machine cannot hold the root image; more RAM, or a smaller image (fewer packages) |
| `netroot: download … failed` | nginx not running, wrong path, or firewall; the message contains curl's own error |
| `netroot: dm-verity refused the image` | `root.img`/`root.verity` in that directory are not the ones the UKI was signed for: republish with `netboot-export.sh` (it checks this before publishing) |
| the screen says `Start PXE over IPv4`, `Station IP address …`, but nginx sees nothing | that is the firmware's **PXE** client, not HTTP boot: it wants a TFTP file name and a TFTP server, an HTTP URL in option 67 fails. Enable HTTP boot and pick the "HTTPv4" entry, or serve the UKI over TFTP (dnsmasq `pxe-service` / proxy DHCP, [Quick one-off test](#quick-one-off-test-on-an-existing-lan)) |
| proxy DHCP (dnsmasq) logs nothing when the client boots | the broadcasts do not reach dnsmasq: another L2 segment (e.g. the build host is a VM behind NAT), or a firewall in between. Proxy DHCP needs UDP 67 and 4011, TFTP UDP 69 (with `--tftp-single-port` nothing else) |
| dnsmasq: `error 8 User aborted the transfer` | harmless if a `sent …` follows: UEFI PXE asks for the file size first (`tsize`) and aborts on purpose. Without a second request the firmware refused the file (too large for it) |
| the client fetches the old boot file after a change | dnsmasq still runs with the previous command line (shell history); restart it with the new one |
| iPXE runs a different script than expected | iPXE (EFI) loads `autoexec.ipxe` from the TFTP server **before** its embedded script; remove a stale one. Arch's `ipxe` package also ships `ipxe-arch.efi`, which boots Arch Linux's own netboot: use `ipxe.efi`/`snponly.efi` |
| a UKI over PXE: downloaded completely, then back to PXE or stuck after `NBP file …` | too large for this firmware's network boot (T450s: 82 MiB works, 112 MiB fails): check the size `mkosi.postoutput` prints, keep the network UKI below the limit ([Size of the network UKI](#size-of-the-network-uki)) |
| on a machine with Intel AMT (vPro, e.g. Intel I218-LM/I219-LM): only iPXE runs over PXE, everything else reboots or hangs | disable Intel AMT in the BIOS ([Case found](#case-found-thinkpad-t450s-bios-jbet73ww)) |
| files arrive completely, then reboot / hang / back to the boot menu, even for small images | the firmware cannot start a network-loaded image (ThinkPad T450s): use a [netstick](#machines-that-cannot-network-boot-the-uki-the-netstick) |
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
  Intel AMT disabled and a UKI that is not much larger than the current 82 MiB (see [Case found](#case-found-thinkpad-t450s-bios-jbet73ww)); with
  AMT on it needs a netstick. In QEMU (OVMF) the whole chain was tested end to end:
  DHCP → UEFI HTTP boot of the signed UKI → DHCP in the initrd → `root.verity` and
  `root.img` over HTTP → `veritysetup open` against the signed root hash → the real
  safespace root mounted → login prompt, with no disk attached to the VM. Real firmware
  differs in how it offers HTTP boot and how large a boot file it accepts.
