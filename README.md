# safespace-arch with mkosi

A Secure-Boot-signed Arch Linux system for USB sticks, SD cards and network boot on x86-64
UEFI machines (no legacy BIOS), built with
[mkosi](https://github.com/systemd/mkosi) (written for mkosi 27). The system is
**read-only**: nothing is written to the boot medium at runtime. The root is protected by
dm-verity, `/var` lives in RAM, and only disks mounted at runtime are writable. Docker
images travel in the image; Docker's storage lives on a data disk at `/opt/docker`.
An XFCE desktop is available over VNC (through an ssh tunnel).

Two variants are built from the same configuration, selected with `./build.sh`:

| | `usb` | `network` |
|---|---|---|
| Build | `sudo ./build.sh usb` | `sudo ./build.sh network` |
| Boots from | a USB stick or SD card (ESP + root + verity on the medium) | UEFI HTTP (or PXE) boot: the firmware itself downloads the signed UKI, nothing is on the machine |
| Root comes from | the medium, read-only and set read-only at block level | HTTP, into a tmpfs, opened through dm-verity with the signed root hash |
| Written with | `sudo ./burn.sh /dev/sdX` | `./netboot-export.sh` onto a netboot server |
| USB devices | the initrd authorizes only the path to the boot medium | nothing on USB is authorized at all (the NIC must be PCI/PCIe) |
| Docs | this file | this file plus **[NETBOOT.md](NETBOOT.md)** |

Everything else is identical: same packages, users, hardening, dm-verity root, volatile
`/var`, Secure Boot signature and `safespace-seal`.

> **Status:** usb variant tested in QEMU (OVMF, stick on emulated USB): boots with and
> without enforced Secure Boot; dm-verity verified, stick read-only at block level; sealing
> with `safespace-seal` (append and `--replace`) and booting the sealed VM. Boots on one real
> machine (Secure Boot in Setup Mode). Network variant tested end to end in QEMU (OVMF,
> no disk attached): DHCP → UEFI HTTP boot of the signed UKI → root image and hash tree over
> HTTP → dm-verity against the signed root hash → login prompt. On real hardware: a ThinkPad
> T450s (no HTTP boot, Intel AMT disabled) boots the same signed UKI over PXE/TFTP end to end;
> UEFI HTTP boot on real hardware is not tested yet.

## Quick start

```sh
# once: host tools
sudo pacman -S --needed mkosi systemd-ukify sbctl efitools dosfstools mtools erofs-utils zstd cpio skopeo
sudo sbctl create-keys        # if you have no Secure Boot keys yet (/var/lib/sbctl)

cp users.conf.example users.conf   # add your users and ssh keys
# optional: safespace.env (VNC), docker-images.txt (images to ship)
./fetch-images.sh             # downloads the listed images (skip if none)

# variant usb: a stick or SD card
sudo ./build.sh usb           # -> mkosi.output/safespace-arch-usb_<date-time>.raw.zst
sudo ./burn.sh /dev/sdX       # writes the newest usb image to the medium
sudo ./diagnose.sh /dev/sdX   # optional: verifies root on the medium block by block

# variant network: UEFI HTTP/PXE boot
sudo ./build.sh network       # URL from netboot.conf, see the next section
./netboot-export.sh --rsync arch.boot.internal:/srv/netboot/safespace

# on the machine, once per data disk (any disk except the boot medium):
sudo mkfs.ext4 -L safespace-docker /dev/<datadisk>
```

`build.sh` runs mkosi with the profile of the variant; root is needed because the
signing key in `/var/lib/sbctl/keys/db/` is readable by root only. Build with `build.sh`
only: before mkosi runs it exports the public Secure Boot keys into the image and creates
the PCR signing key on the first build; a plain `mkosi build` stops at the key check
(and without a profile even earlier).

Not tracked by git, created per user or host: `users.conf`, `netboot.conf`,
`mkosi.local.conf`, `repos.local.conf`, the exported keys
(`mkosi.extra/usr/share/safespace/secureboot/`), shipped images
(`mkosi.extra/usr/share/safespace/docker-images/`), caches, outputs and the staged
netboot tree (`mkosi.netboot/`).

## Network boot: build and provide

Everything needed to build the `network` variant and put it in front of the machines, in
order. This installation uses the name **`arch.boot.internal`** for the netboot server and
`/srv/netboot/safespace` as the tree; the server itself (nginx, dnsmasq, DHCP options,
Secure Boot enrollment, troubleshooting) is described in **[NETBOOT.md](NETBOOT.md)**.

| | Value |
|---|---|
| netboot server (DNS A record) | `arch.boot.internal` |
| its IP address (example, replace it everywhere below) | `10.0.0.1` |
| tree on the server | `/srv/netboot/safespace/<version>/` plus `current -> <version>` |
| boot file for the DHCP answer | `http://arch.boot.internal/safespace/current/boot.efi` |
| root image URL signed into the UKI | `http://arch.boot.internal/safespace/<version>/` (from `netboot.conf`) |

### Once, on the build host

```sh
sudo pacman -S --needed mkosi systemd-ukify sbctl efitools dosfstools mtools erofs-utils zstd cpio skopeo
sudo sbctl create-keys                  # if there are no Secure Boot keys yet
cp users.conf.example users.conf        # your users and ssh keys
cp netboot.conf.example netboot.conf    # NETROOT_URL=http://arch.boot.internal/safespace/
```

`netboot.conf` is where the name lives; `build.sh` appends the build version to it and signs
the result into the UKI, which is why **changing the server address means rebuilding** — a
name keeps that from happening when the server moves. Several URLs can be listed, tried in
order (name first, address as fallback).

### Once: ramp up the server

On the machine that `arch.boot.internal` will point at — a dedicated netboot server, or the
build host itself for a first test. All it does is serve the three files each machine
downloads, over plain HTTP: the integrity comes from the Secure Boot signature and
dm-verity, not from the transport. `10.0.0.1` below stands for that machine's address
(`ip -4 -br addr`).

```sh
# 1. web server (Arch; Debian/Ubuntu: apt install nginx-light)
sudo pacman -S --needed nginx

# 2. the tree the images are published into
sudo install -d -m 0755 /srv/netboot/safespace
# so netboot-export.sh --rsync can write without root ssh; use the account you
# ssh in as from the build host
sudo chown -R "$USER" /srv/netboot/safespace

# 3. site configuration (Arch ships no conf.d/, create it first)
sudo install -d -m 0755 /etc/nginx/conf.d
sudo tee /etc/nginx/conf.d/netboot.conf >/dev/null <<'NGINX'
server {
    listen        80 default_server;
    listen        [::]:80 default_server;
    server_name   _;
    root          /srv/netboot;

    autoindex     off;
    sendfile      on;
    tcp_nopush    on;
    server_tokens off;

    location / { limit_except GET HEAD { deny all; } }
}
NGINX
# the main config has to pull conf.d in (Debian uses sites-enabled instead)
grep -qE '^[[:space:]]*include[[:space:]]+(/etc/nginx/)?conf\.d/\*\.conf;' /etc/nginx/nginx.conf ||
    sudo sed -i '/^http {/a \    include conf.d/*.conf;' /etc/nginx/nginx.conf
# Arch's nginx.conf also has a stock "server { listen 80; server_name localhost; }"
# block. It does no harm (netboot.conf is the default_server, so requests by IP or by
# arch.boot.internal land there), but it can be deleted.

# 4. start it
sudo nginx -t && sudo systemctl enable --now nginx

# 5. firewall, only if one is active on this host
sudo nft add rule inet filter input tcp dport 80 accept   # nftables
# sudo firewall-cmd --permanent --add-service=http && sudo firewall-cmd --reload
```

Check it, after the first `./netboot-export.sh --tree`/`--rsync` (see "Every build") has
published a build:

```sh
curl -I http://arch.boot.internal/safespace/current/boot.efi    # 200 + Content-Length
```

`Content-Length` matters: the initrd uses it to size its tmpfs and to check there is enough
RAM before downloading. nginx sends it for static files.

Without nginx, for a throwaway test from the build host, this serves the staged tree under
the same path (needs root for port 80, and it stays in the foreground):

```sh
mkdir -p mkosi.test/docroot
ln -sfnT "$PWD/mkosi.netboot" mkosi.test/docroot/safespace
sudo python3 -m http.server 80 --directory mkosi.test/docroot
```

### Once: configure DNS (you have to do this)

The name is not optional: it is signed into the UKI, and the machines have no other way to
find the root image. Create an **A record** `arch.boot.internal` → the IP of the server you
just set up (`10.0.0.1` in the examples), in the DNS server that your DHCP
hands out to the clients. Examples:

| DNS server | What to add |
|---|---|
| dnsmasq | `host-record=arch.boot.internal,10.0.0.1` (or `address=/arch.boot.internal/10.0.0.1`) |
| BIND, zone `boot.internal` | `arch    IN  A   10.0.0.1`, then `rndc reload` |
| Unbound (OPNsense/pfSense: *Overrides*) | `local-data: "arch.boot.internal. A 10.0.0.1"` |
| Pi-hole | *Local DNS → DNS Records*: `arch.boot.internal` → `10.0.0.1` |
| Windows DNS | `dnscmd . /recordadd boot.internal arch A 10.0.0.1` |

Verify from a machine on the same network as the clients (not from the server itself):

```sh
getent hosts arch.boot.internal          # or: nslookup arch.boot.internal
curl -I http://arch.boot.internal/safespace/current/boot.efi
```

If the name cannot be resolved, `netroot` says `Could not resolve host` on the client's
console. You can ride that out by listing a second URL with a plain IP address in
`netboot.conf` (tried in order) and rebuilding.

### Once: tell the machines what to boot (DHCP)

The machines learn what to boot from **DHCP**; that is the only thing that changes in your
network. There are two ways, both pure UEFI firmware booting the signed UKI directly — no
iPXE, no boot loader in between:

| | UEFI HTTP boot (the intended path) | UEFI PXE/TFTP (old firmware without HTTP boot) |
|---|---|---|
| firmware boot entry | "UEFI HTTPv4 …" / "HTTP Boot" | "UEFI PXEv4 …" / "Start PXE over IPv4" |
| client asks with | option 60 `HTTPClient:Arch:00016`, option 93 = 16 | option 60 `PXEClient:Arch:00007`, option 93 = 7 or 9 |
| answer: option 60 | `HTTPClient` | `PXEClient` (dnsmasq: `pxe-service=`) |
| answer: option 67 | `http://10.0.0.1/safespace/current/boot.efi` (full URL) | `safespace/current/boot.efi` (path under the TFTP root) |
| answer: next server | — | `10.0.0.1`, which runs TFTP |
| who can answer | the network's DHCP server | the DHCP server, **or** proxy DHCP next to it (`pxe-proxy.sh`) |
| speed for the ~82 MiB UKI | seconds | ~1 min |

**So yes: pure UEFI HTTP boot is options 60 and 67**, and both have to come from the DHCP
server that hands out the address. The proxy-DHCP trick (`pxe-proxy.sh`) does not work for
it: dnsmasq in proxy mode only answers clients that announce `PXEClient`. Use the server's
IP in option 67 rather than the name: the firmware's own resolver is one more thing that can
fail, and this value can be changed any time without rebuilding the image (the name matters
for the URL *inside* the UKI).

#### HTTP boot: the network's DHCP server sends 60 and 67

If dnsmasq is your DHCP server, this is the whole change
([NETBOOT.md §3](NETBOOT.md#3-dhcp-and-the-boot-file) has ISC dhcpd, Kea,
OPNsense/pfSense and Windows Server, and both paths in one configuration):

```ini
# /etc/dnsmasq.d/netboot.conf
dhcp-vendorclass=set:httpclient,HTTPClient:Arch:00016
dhcp-match=set:httpclient,option:client-arch,16
dhcp-option-force=tag:httpclient,60,HTTPClient
dhcp-boot=tag:httpclient,http://10.0.0.1/safespace/current/boot.efi
log-dhcp
```

```sh
sudo systemctl restart dnsmasq
journalctl -u dnsmasq -f        # watch a machine ask and get the URL
```

Other DHCP servers: set option 60 = `HTTPClient` and option 67 = the URL, **only** for
clients whose option 60 starts with `HTTPClient` — a PXE client that gets an HTTP URL fails
with `PXE-E23`. On the machine: firmware setup → network stack and HTTP boot on, boot menu
(F12) → the HTTP entry. nginx then logs `boot.efi`, `root.verity`, `root.img`.

#### PXE/TFTP: proxy DHCP from the build host, the router stays untouched

For machines whose firmware only offers PXE (e.g. ThinkPad T450s; with Intel AMT
**disabled**, see [NETBOOT.md](NETBOOT.md#case-found-thinkpad-t450s-bios-jbet73ww)), or
when the router cannot send boot options at all. `pxe-proxy.sh` runs dnsmasq in the
foreground: proxy DHCP (the router keeps handing out addresses) plus TFTP for the UKI from
`/srv/netboot`. The root image still comes from nginx over HTTP.

```sh
sudo pacman -S --needed dnsmasq
# firewall on this host, if one is active: UDP 67, 69 and 4011
sudo ./pxe-proxy.sh safespace/current/boot.efi          # Ctrl-C stops it
```

Interface and subnet come from the default route (`--interface`, `--subnet` to override),
the log goes to the terminal and `mkosi.test/dnsmasq.log`. On the machine: boot menu
(F12) → the PXE / "PCI LAN" entry. Proxy DHCP only reaches machines on the same L2
segment.

### Once: Secure Boot on the machines

Enroll your `db` certificate, or boot a machine once in Setup Mode and run
`sudo safespace-seal` on it — see
[NETBOOT.md](NETBOOT.md#secure-boot-on-the-clients). Until then, boot with Secure Boot off;
the dm-verity protection of the root image works either way, but the command line (and with
it the root hash) is only trustworthy with Secure Boot on.

### Every build

```sh
sudo ./build.sh network                 # -f to rebuild unchanged packages

# the server is another machine: publish locally and copy it over in one step
./netboot-export.sh --rsync arch.boot.internal:/srv/netboot/safespace

# or, if this build host serves the files itself: publish straight into the tree
./netboot-export.sh --tree /srv/netboot/safespace

# what the server serves now
ls -l /srv/netboot/safespace/current/        # on the server: boot.efi root.img root.verity ...
curl -I http://10.0.0.1/safespace/current/boot.efi
```

To try a build on one machine before the others get it, publish it without moving
`current` and point only that boot at it (PXE via `pxe-proxy.sh`; for HTTP boot, put the
version into option 67 instead of `current`):

```sh
sudo ./build.sh network --debug         # --debug: ethtool, tcpdump, ... and "-debug" in the version
V=$(basename "$(ls -t mkosi.output/safespace-arch-network_*.efi | head -1)" .efi); V=${V#safespace-arch-network_}; echo "$V"
./netboot-export.sh --tree /srv/netboot/safespace --version "$V" --no-current
sudo ./pxe-proxy.sh "safespace/$V/boot.efi"
```

Without `--rsync` or `--tree`, `./netboot-export.sh` only stages into `mkosi.netboot/` in
the project; nothing reaches the server. A staged tree can still be copied later:
`cp -a mkosi.netboot/. /srv/netboot/safespace/` (or `rsync -a` to the server); `current` is
a relative symlink and survives the copy.

`build.sh` writes `mkosi.output/safespace-arch-network_<version>.{efi,root.raw.zst,root-verity.raw.zst,roothash}`.
`netboot-export.sh` turns those into the three files the machines ask for — `boot.efi`,
`root.img`, `root.verity` — in `<tree>/<version>/`, checks that they belong together (root
hash from the signed UKI, `veritysetup verify` over the whole image, which key signed it),
moves `current` to the new version and, with `--rsync`, copies everything to the server. Machines take the new
version on their next boot; a running machine is unaffected, it has everything in RAM.

Rollback is moving the symlink back, on the server:

```sh
cd /srv/netboot/safespace && ln -sfn <older-version> .current.new && mv -T .current.new current
```

Old versions stay bootable while they are there (~2 GiB each); `./netboot-export.sh --prune 3`
keeps the last three locally.

### Check it

```sh
curl -I http://arch.boot.internal/safespace/current/boot.efi    # 200 + Content-Length
./test-vm.sh --netboot --url http://10.0.0.1/safespace/current/boot.efi --ssh 2222   # optional: QEMU
```

`test-vm.sh --netboot --url` boots the published build in QEMU by pure UEFI HTTP boot from
the real server (through QEMU's NAT, names resolved by the host), as a machine on the LAN
would.

Without `--url` the rehearsal serves a local tree and needs an image built for the VM's view
of the host (`sudo ./build.sh network --url http://10.0.2.2:8000/`) — see
[NETBOOT.md](NETBOOT.md#optional-rehearse-it-in-qemu-first). On a booted machine:
`journalctl -b -g netroot`, `findmnt /`, `veritysetup status root`, `df -h /run/netroot`.

### A netbooting VM (QEMU, libvirt / virt-manager)

A VM that boots the published build exactly like a machine on the LAN: pure UEFI HTTP boot of
the signed UKI from the server, no disk, no iPXE. Two forms, both tested: a plain
`qemu-system-x86_64` command, or a persistent libvirt machine that shows up in virt-manager.

Common to both:

- **Firmware:** OVMF with Secure Boot and **no** enrolled keys, so the VM starts in Setup
  Mode; `sudo safespace-seal` inside seals it, and from the next start on it boots the UKI only
  with enforced Secure Boot. Its NVRAM (a file of its own) keeps that state. With enrolled
  keys, libvirt's Secure Boot firmware would trust only Microsoft's and refuse the UKI.
- **PXE off in the firmware:** OVMF creates PXEv4, PXEv6, HTTPv4 and HTTPv6 boot entries for
  the NIC, PXE first. The PXE entry gets the URL, cannot use it and fails, and only then does
  HTTPv4 load the UKI. Two fw_cfg settings of OVMF remove the PXE entries, so the firmware
  goes straight to `Start HTTP Boot over IPv4`: `opt/org.tianocore/IPv4PXESupport=n` and
  `opt/org.tianocore/IPv6PXESupport=n`. They apply to the boot entries the firmware creates;
  an NVRAM that already has PXE entries is reset once (below).
- **DHCP and DNS** come from the virtual network (QEMU's user network or a libvirt NAT
  network), which uses the **resolver of the VM host**. A host name in the root URL (the
  `NETROOT_URL` signed into the UKI) only resolves if that host's DNS knows it. If not, use
  the server's IP in `netboot.conf`, or the name plus the IP as fallback
  (`NETROOT_URL="http://arch.boot.internal/safespace/ http://10.0.0.1/safespace/"`, tried in
  order), and rebuild. Check on the VM host: `getent hosts arch.boot.internal`.
- **RAM:** at least root.img + 2 GiB (4 GiB).
- **Guest agent:** the image has `qemu-guest-agent`. It starts by itself when the VM has the
  agent channel (virtio port `org.qemu.guest_agent.0`) and reports IP addresses, OS, host
  name, users and filesystems to the VM host. It only answers those queries and
  `guest-shutdown` (`/etc/qemu/qemu-ga.conf`, `allow-rpcs=`): no `guest-exec`, no file
  access, no password setting, so the VM host gets no command channel into the system.

#### Plain QEMU, headless

On any host with QEMU and OVMF, no checkout needed. Arch paths; Debian/Ubuntu:
`/usr/share/OVMF/OVMF_CODE_4M.secboot.fd` and `OVMF_VARS_4M.fd`. Runs in the foreground,
also as root over ssh without a desktop; Ctrl-C stops it.

```sh
cp /usr/share/edk2/x64/OVMF_VARS.4m.fd safespace-vm-vars.fd      # once: the VM's NVRAM
qemu-system-x86_64 -machine q35,smm=on,accel=kvm -cpu host -smp 2 -m 4096 -global driver=cfi.pflash01,property=secure,value=on -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd -drive if=pflash,format=raw,file=safespace-vm-vars.fd -fw_cfg name=opt/org.tianocore/IPv4PXESupport,string=n -fw_cfg name=opt/org.tianocore/IPv6PXESupport,string=n -nic user,model=virtio-net-pci,bootfile=http://10.0.0.1/safespace/current/boot.efi,hostfwd=tcp:127.0.0.1:2222-:22 -device virtio-serial -chardev socket,id=qga,path=safespace-vm-qga.sock,server=on,wait=off -device virtserialport,chardev=qga,name=org.qemu.guest_agent.0 -boot order=n -display none -serial file:safespace-vm-serial.log
ssh -p 2222 <user>@127.0.0.1                                      # after ~1 min; a user from users.conf
echo '{"execute":"guest-network-get-interfaces"}' | socat - UNIX-CONNECT:safespace-vm-qga.sock   # the guest agent
```

| Part | Why |
|---|---|
| `OVMF_CODE.secboot.4m.fd` (read-only pflash) | the UEFI firmware, shared by all VMs; the build with Secure Boot |
| `safespace-vm-vars.fd` (writable pflash) | this VM's NVRAM: boot entries and the Secure Boot keys `safespace-seal` writes. A fresh copy = Setup Mode again |
| `smm=on`, `cfi.pflash01,property=secure` | only the firmware (in SMM) may write the keys, not the guest |
| `-fw_cfg name=opt/org.tianocore/IPv4PXESupport,string=n` (and IPv6) | no PXE boot entries: HTTP boot right away |
| `-nic user,…,bootfile=` | QEMU's user network is the DHCP server, `bootfile=` is its option 67 (the server's IP, so the firmware needs no DNS) |
| `hostfwd=tcp:127.0.0.1:2222-:22` | ssh into the VM from this host only (`tcp::2222-:22` opens it to the network) |
| `-device virtio-serial`, `-chardev socket,…`, `virtserialport,…name=org.qemu.guest_agent.0` | the guest agent's channel; on the VM host it is the socket `safespace-vm-qga.sock` |
| `-display none`, `-serial file:…` | no window; `safespace-vm-serial.log` shows the firmware's netboot (`Start HTTP Boot over IPv4`, `Downloading...100%`). The kernel console is not on the serial port (no `console=ttyS0` in the UKI), so the system is reached over ssh |

Without Secure Boot in the VM: `OVMF_CODE.4m.fd`, and drop `smm=on` and the `-global` option.

#### Persistent machine in libvirt (virt-manager)

libvirt's user network has no `bootfile=`, so the boot URL comes from the DHCP server of a
small libvirt NAT network of its own; other networks and VMs stay untouched. As root on the
VM host (change `192.168.150.0/24` if it is in use there).

1. The network; its DHCP sends the boot URL (option 67):

   ```sh
   virsh net-define /dev/stdin <<'EOF'
   <network>
     <name>safespace-netboot</name>
     <forward mode='nat'/>
     <bridge name='virbr-ssnb'/>
     <ip address='192.168.150.1' netmask='255.255.255.0'>
       <dhcp>
         <range start='192.168.150.100' end='192.168.150.199'/>
         <bootp file='http://10.0.0.1/safespace/current/boot.efi'/>
       </dhcp>
     </ip>
   </network>
   EOF
   virsh net-autostart safespace-netboot && virsh net-start safespace-netboot
   ```

2. The machine: UEFI with Secure Boot and no keys (Setup Mode), no disk, the NIC as the only
   boot device:

   ```sh
   virt-install --name safespace-netboot --memory 4096 --vcpus 2 --cpu host-passthrough --machine q35 --boot uefi,network,firmware.feature0.name=secure-boot,firmware.feature0.enabled=yes,firmware.feature1.name=enrolled-keys,firmware.feature1.enabled=no --network network=safespace-netboot,model=virtio --disk none --pxe --osinfo linux2022 --graphics vnc --noautoconsole
   ```

3. PXE off: `virsh edit safespace-netboot` and add, directly inside `<domain>`
   (libvirt ≥ 6.5):

   ```xml
   <sysinfo type='fwcfg'>
     <entry name='opt/org.tianocore/IPv4PXESupport'>n</entry>
     <entry name='opt/org.tianocore/IPv6PXESupport'>n</entry>
   </sysinfo>
   ```

   Then start it once with a fresh NVRAM, so the PXE entries of the first start go away. This
   also clears its Secure Boot keys: seal the VM after this start, not before.

   ```sh
   virsh destroy safespace-netboot; virsh start safespace-netboot --reset-nvram
   ```

The VM appears in virt-manager as `safespace-netboot`, with its console there. `virt-install`
adds the guest agent channel by itself, so virt-manager shows the VM's IP addresses
(Details → NIC). Its address, for ssh from the VM host:

```sh
virsh domifaddr safespace-netboot --source agent     # or: virsh net-dhcp-leases safespace-netboot
ssh <user>@192.168.150.1xx
virsh qemu-agent-command safespace-netboot '{"execute":"guest-get-osinfo"}'   # answers
virsh qemu-agent-command safespace-netboot '{"execute":"guest-exec","arguments":{"path":"/bin/true"}}'   # refused: command disabled
```

It boots what `current` points to; to pin a version, put it into `<bootp file=…>`
(`virsh net-edit safespace-netboot`, then `virsh net-destroy` and `virsh net-start`). Remove
it all again:

```sh
virsh destroy safespace-netboot; virsh undefine --nvram safespace-netboot; virsh net-destroy safespace-netboot; virsh net-undefine safespace-netboot
```

## The boot medium is never written to

| Layer | How |
|---|---|
| Partitions | only ESP, root and root-verity (network variant: no partitions at all on the machine) |
| Root (`/usr` and `/etc`) | erofs (read-only filesystem) on dm-verity. The root hash is part of the signed kernel command line, so any changed block fails to read |
| `/var` | tmpfs (`systemd.volatile=state`), filled on every boot from the verified copy in `/usr/share/factory/var` (`safespace-var-factory.service`). Everything written there is gone after reboot |
| ESP | never mounted (`efi`/`boot` mounts masked); no `loader/random-seed` on it, so systemd-boot writes nothing; `systemd-boot-update`, `systemd-boot-random-seed` and systemd-repart are masked |
| Block level | usb: after finding root, the initrd step `usb-bootdev` runs `blockdev --setro` on the medium and all its partitions, so the kernel refuses writes to it, even from root. network: the root image is a read-only loop device over a tmpfs file |

Writable storage exists only on disks mounted at runtime, such as the Docker data disk.

Partitions of the `usb` image (what `burn.sh` writes):

| # | Partition | Content |
|---|---|---|
| 1 | ESP, 512 MiB, FAT | signed systemd-boot `\EFI\BOOT\BOOTX64.EFI`, signed UKI `\EFI\Linux\*.efi` |
| 2 | root, erofs (zstd) | `/usr`, `/etc`, factory `/var`, shipped Docker images |
| 3 | root-verity | dm-verity hash tree for partition 2 |

The `network` image has partitions 2 and 3 only; they are published as separate files
(`root.img`, `root.verity`) and the UKI is served on its own. See
[NETBOOT.md](NETBOOT.md).

## How the integrity protection works

dm-verity itself uses **no keys**. It's a sha256 hash tree over root, and its only anchor of
trust is the **root hash**. That hash sits in the kernel command line inside the UKI, and
the UKI is signed with your sbctl **`db` key**. So everything rests on the Secure Boot
signature:

1. Firmware checks the signatures of systemd-boot and, through it, of the UKI against the
   `db` certificate enrolled in it (PK and KEK only control changes to `db`; the build only
   uses `db.key`).
2. The command line is part of the signed file. Under Secure Boot, systemd-stub ignores any
   command line passed from outside.
3. The initrd (also signed) reads `roothash=`. usb: it finds the root and hash partitions by
   the UUIDs derived from it. network: it downloads `root.img` and `root.verity` from the URL
   on the signed command line and opens them with that hash. Either way the result is
   `/dev/mapper/root`, and a wrong or manipulated root is rejected before it is mounted.
4. The kernel checks every block read from root against the tree. A mismatch stops the system
   (`panic-on-corruption`).

The ESP itself isn't covered by dm-verity, and systemd-stub reads more than the UKI from it.
Those paths are closed on the signed command line:

| ESP content | Protection |
|---|---|
| add-ons (`*.addon.efi`) | only loaded if signed by a key in `db` |
| credentials (`*.cred`) | `systemd.credentials_boot_policy=strict`: no null-key credentials (the default would accept them on machines without TPM2) |
| extension images (`*.sysext.raw`, `*.confext.raw`) | `systemd.sysext=0`, `systemd.confext=0` and `rd.` variants; the units are also masked in the initrd and on the system |

`diagnose.sh` checks all of this on a burned stick, including that the ESP holds nothing but
systemd-boot and the UKI. For the network variant, `netboot-export.sh` does the equivalent
check before publishing (root hash in the UKI vs. the published images, `veritysetup verify`
over the whole root image, and which key signed the UKI).

**Preconditions:** Secure Boot on and a firmware password on every machine. Without Secure Boot,
any command line (and with it any `roothash=`) can be passed in. The `db` key decides
everything: whoever has it can sign a UKI for a manipulated root.

## Sealing a machine to these keys

The stick can enroll its own Secure Boot keys on a machine, so that the machine afterwards
only boots binaries signed with them (the "seal").

**On the build host: nothing extra.** Every image is signed, so every image carries the
public half of the keys it is signed with: `build.sh` runs `secureboot-export.sh` before each
build (usb and network alike), with the sbctl directory of `SecureBootKey=`. It puts into
`mkosi.extra/usr/share/safespace/secureboot/` (gitignored) the PK, KEK and db certificates
and the signed updates (`*.auth`) the firmware needs to enroll them. The private keys are
only used to sign those updates (PK signs PK and KEK, KEK signs db) and stay in
`/var/lib/sbctl`. `mkosi.postoutput` fails the build if the keys are missing (mkosi run
without `build.sh`), if anything but certificates, `*.auth` and `GUID` is in that directory,
or if any file there contains a private key, and if the UKI is signed by a different key
than the shipped `db.pem` (a machine sealed with it would refuse that UKI). After rotating
keys in sbctl, the next build ships the new ones.

**On the machine:**

1. Firmware setup: "Reset to Setup Mode" or "Clear Secure Boot keys". Boot the stick (Secure
   Boot can't be enforced without keys, so it boots).
2. `sudo safespace-seal`: shows what's enrolled now and what will be enrolled, asks for YES,
   writes db, KEK and finally PK (writing PK ends Setup Mode).
3. Reboot, check that Secure Boot is enabled in the firmware setup, and set a firmware
   password.

By default our KEK and db are **added** to whatever the firmware still has, so Microsoft or
vendor certificates stay if present. Option ROMs of GPUs, NICs or RAID controllers are usually
signed by Microsoft, and without that certificate in db they don't load: no picture in the
firmware setup, or a machine that doesn't boot. `safespace-seal --replace` enrolls **only**
our keys. Use it only on machines without such devices, e.g. integrated graphics only.

Try it in a VM: `./test-vm.sh --setup-mode --ssh 2222`, log in, `sudo safespace-seal`, power
off, then `./test-vm.sh --sealed`.

A netbooted machine can seal itself the same way: boot it in Setup Mode (no keys, so the
unverified UKI loads), run `sudo safespace-seal`, reboot — from then on the firmware
verifies the downloaded UKI against your `db`. See
[NETBOOT.md](NETBOOT.md#secure-boot-on-the-clients).

## Docker

**Why a data disk is needed:** Docker can't run from read-only storage. Its storage
(`data-root`) is constantly written: layer metadata, image references, container layers,
volumes, networks. RAM (`/var`) would fill up quickly. So:

- `/etc/docker/daemon.json`: `data-root` is `/opt/docker/engine`, storage driver `overlay2`.
  Docker 29's default containerd image store is switched off on purpose, so all images live
  in `data-root` and image IDs can be checked against the shipped archives.
- `/etc/containerd/config.toml`: containerd's data goes to `/opt/docker/containerd`.
- **Docker is not started at boot** (not enabled in the preset). Start it by hand once the
  data disk is mounted: `sudo systemctl start docker`. As a second guard, `docker.service`,
  `docker.socket` and `containerd.service` only start when `/opt/docker` is a mount point
  (`ConditionPathIsMountPoint`), so Docker never runs on the read-only root or in RAM.
- `/etc/fstab` mounts a disk labelled **`safespace-docker`** at `/opt/docker` if present at boot
  (`nofail`, 10 s timeout). The filesystem must support overlay2: ext4, xfs with ftype=1, or
  btrfs.
- Start Docker: `sudo systemctl start docker` (disk present at boot), or for a disk attached
  later `sudo mount /dev/<datadisk> /opt/docker && sudo systemctl start docker`.

**Images on the stick:**

1. List them in `docker-images.txt` as `<local name:tag> <source>`, with the source pinned by
   digest (`docker.io/library/nginx@sha256:…`).
2. `./fetch-images.sh` downloads them with skopeo as archives into
   `mkosi.extra/usr/share/safespace/docker-images/`, plus `images.list` with each image ID.
3. The build puts them into the dm-verity protected root, so they're verified like everything
   else.
4. When Docker starts, `safespace-docker-images.service` loads any image whose expected ID
   isn't present on the data disk, and fails if a loaded image has a different ID.

Container data, volumes and anything pulled at runtime stay on the data disk.

**USB data disks:** usbguard blocks every USB device plugged in after boot. A Docker disk on
USB needs `sudo usbguard allow-device <id>` after plugging it in (temporary; `-p` can't be
written to the read-only `/etc`). Or add a permanent rule to
`mkosi.extra/etc/usbguard/rules.conf` and rebuild (`usbguard generate-policy` shows the
rule syntax). Disks on SATA or NVMe aren't affected.

## What differs from a plain mkosi build

Everything below is on top of what `mkosi build` with `Distribution=arch` and stock Arch
packages would give you. Stock Arch defaults (e.g. the nftables ruleset in
`/etc/nftables.conf`: input policy drop, ssh allowed) are not listed.

### Build configuration (`mkosi.conf`, `mkosi.profiles/`, `repos.conf`)

`mkosi.conf` holds everything both variants share; the differences are in
`mkosi.profiles/usb/` and `mkosi.profiles/network/`, which mkosi merges in when that
profile is active (`./build.sh <variant>` = `mkosi --profile=<variant>`). `mkosi.postinst`
stops the build if no variant is selected.

| Setting | Why |
|---|---|
| `Profiles=` (`--profile`) | `usb` or `network`; also inherited by the initrd, so `mkosi.initrd.conf/mkosi.profiles/<variant>/` ends up in the initrd |
| `ImageId=safespace-arch-usb` / `-network` | per variant, so both can live in `mkosi.output/` and `burn.sh`/`test-vm.sh` never pick the wrong one |
| `Format=disk`, `Bootable=yes` | bootable GPT image |
| `Bootloader=systemd-boot` | mkosi's default for this setup would be a bare UKI as `\EFI\BOOT\BOOTX64.EFI`. Some firmware resets when its boot manager starts a 90 MiB UKI directly, but loads it fine for systemd-boot (see "Troubleshooting") |
| `ElTorito=no` | mkosi 27 adds an ISO9660/El Torito header for CD boot by default; a stick boots via GPT |
| `SecureBoot=yes`, `SecureBootKey`/`Certificate` from `/var/lib/sbctl`, `SecureBootSignTool=systemd-sbsign`, `SecureBootAutoEnroll=no` | systemd-boot and the UKI are signed with the sbctl `db` key; no systemd-boot auto-enrollment files on the ESP (`safespace-seal` does enrollment) |
| `SignExpectedPcr=yes`, `SignExpectedPcrKey`/`Certificate` in `/var/lib/safespace/pcr-signing/` | the UKI carries signed expected PCR 11 values and the PCR public key (`.pcrsig`, `.pcrpkey`): systemd's NvPCRs can be set up, and TPM secrets can be bound to "a UKI signed by this host". Own key, created by `build.sh` on the first build (root-only, never in the image) |
| `Verity=hash` | dm-verity root; the root hash is on the signed kernel command line, no signature partition needed |
| `SplitArtifacts=uki,roothash` (+`partitions` for network), `ManifestFormat=json` | UKI, root hash and package list next to the image; the network variant also writes the root and verity partitions as separate files to publish |
| `CompressOutput=zstd`, `CompressLevel=10` | image as `.raw.zst`, only as large as its content |
| `OutputDirectory=mkosi.output` | outputs out of the project root |
| `--snapshot=`/`--mirror=` from `repos.conf` | set by `build.sh`, not in `mkosi.conf`: pinned Arch Linux Archive day or `latest`, default or own mirror (see ["Package source"](#package-source-snapshot-and-mirror)) |
| `Incremental=yes`, `CacheDirectory=`, `PackageCacheDirectory=` | two cache levels: downloaded packages and the installed system |
| `Environment=SYSTEMD_REPART_MKFS_OPTIONS_VFAT=-S512` | FAT with 512-byte sectors (many firmwares don't read 4K-sector FAT on USB), while erofs and verity keep 4K blocks |
| `Ssh=never` | no sshd-over-vsock units for `mkosi vm` |
| `Hostname=`, `Locale=`, `Keymap=`, `Timezone=` | safespace, en_US.UTF-8, us, UTC |
| `mkosi.version` | `ImageVersion` is the build timestamp, so every build gets its own files. `build.sh` runs it once and passes `--image-version`, so the same value can go into the netboot URL |
| `KernelCommandLine=` of the network variant | `root=/dev/mapper/root`, `rootfstype=erofs`, `ro`, `systemd.verity=no` (the initrd opens the verity device itself) and `safespace.netroot=<url>/<version>/` (where to fetch root from, signed in) |
| `mkosi.local.conf.example` | per-host settings, e.g. more erofs compression threads |

### Disk layout (`mkosi.repart/`, `mkosi.profiles/usb/mkosi.repart/`)

| File | Partition |
|---|---|
| `mkosi.profiles/usb/mkosi.repart/00-esp.conf` | usb variant only: 512 MiB FAT32 with systemd-boot and the UKI only. Excluded: `intel-ucode.img` (the UKI has its microcode), `loader/` (no loader.conf, no type 1 entries, no random seed), `\EFI\systemd\` (only needed for NVRAM boot entries), `BOOTIA32.EFI` |
| `10-root.conf` | erofs, zstd level 12, `Minimize=best`; without `/var`, `/efi`, `/boot` |
| `11-root-verity.conf` | dm-verity hash tree for root |

### Kernel command line (`KernelCommandLine=`, signed into the UKI)

| Option | Effect |
|---|---|
| `systemd.volatile=state` | `/var` is a tmpfs |
| `usbcore.authorized_default=0` | the kernel authorizes no USB device by itself |
| `systemd.credentials_boot_policy=strict` | no null-key credentials from the ESP |
| `systemd.sysext=0`, `systemd.confext=0`, `rd.systemd.sysext=0`, `rd.systemd.confext=0` | no extension images over `/usr` and `/etc` |
| `systemd.verity_root_options=panic-on-corruption` (usb) | a modified root block stops the system; the network variant passes `--panic-on-corruption` to `veritysetup` instead |
| `systemd.firstboot=off` | no first-boot questions |
| `root=/dev/mapper/root`, `rootfstype=erofs`, `ro`, `systemd.verity=no` (network) | the initrd opens the downloaded verity device under that name, so systemd must not look for partitions |
| `safespace.netroot=<url>/<version>/` (network) | where `netroot` fetches `root.img` and `root.verity`; signed, so it cannot be redirected |

### Initrd (`mkosi.initrd.conf/`, `InitrdPackages=`, `KernelInitrdModules=`)

- Both variants: `coreutils`, `sed`, `kmod` for the scripts below; sysext/confext units
  masked in the initrd as well; `CompressLevel=19`. Drivers: one explicit list instead of
  mkosi's default set (dm-verity, loop, erofs, crypto, virtio for QEMU, in `mkosi.conf`),
  plus the boot path per variant. Removed, to keep the UKI small (NETBOOT.md, "Size of the
  network UKI"): filesystem tools, systemd tools without a job in the initrd, glibc's
  charset converters, sanitizer runtimes, certificate CLIs, sqlite tools, `magic.mgc`,
  terminal/timezone/keymap data beyond the console defaults
  (`mkosi.initrd.conf/mkosi.conf`).
- usb (`mkosi.profiles/usb/`, `mkosi.initrd.conf/mkosi.profiles/usb/`): drivers for USB
  host controllers, USB storage, MMC and card readers; `usb-bootdev.service` and
  `/usr/local/lib/safespace/usb-bootdev`, see "USB lockdown".
- network (`mkosi.profiles/network/`, `mkosi.initrd.conf/mkosi.profiles/network/`): client
  ethernet drivers (and their firmware), `curl`, `cryptsetup`, `iproute2`; `20-netboot.network` (DHCP on physical
  ethernet) and `netroot.service` + `/usr/local/lib/safespace/netroot`, which waits for
  DHCP, downloads `root.verity` and `root.img` into a tmpfs under `/run/netroot` (checking
  `MemAvailable` first), and opens them with the signed root hash as `/dev/mapper/root`.
  The tmpfs stays after switch-root: that file *is* the root filesystem. Several
  `safespace.netroot=` URLs are tried in order.

### Build scripts

| Script | What it does |
|---|---|
| `mkosi.postinst` | users from `users.conf` without password (`*`) and with groups from `safespace.env`; their ssh keys into the read-only `/etc/ssh/authorized_keys/<user>`; root locked; `/home` → `/var/home`, `/root` → `/var/roothome`; sudoers check; usbguard daemon settings (block new devices, keep present ones, IPC for `wheel`); VNC password (random per build, saved next to the image); mount points `/efi`, `/var`, `/opt/docker` |
| `mkosi.finalize` | `resolv.conf` → systemd-resolved stub; moves the built `/var` to `/usr/share/factory/var` (caches and logs dropped) |
| `mkosi.postoutput` | fails the build if the UKI is larger than 100 MiB (network: 128 MiB, it carries the ethernet drivers), if it is signed by another key than the exported `db.pem`, or if a network build has no `safespace.netroot=` URL |

### Files in the system (`mkosi.extra/`)

| Area | Files |
|---|---|
| Read-only system | `etc/fstab` (ESP never mounted, Docker data disk); `safespace-var-factory.service` fills `/var` from the factory copy on every boot; masked: `boot.mount`, `boot.automount`, `efi.mount`, `efi.automount`, `systemd-repart`, `systemd-boot-random-seed`, `systemd-boot-update`, all sysext/confext units |
| ssh | `sshd_config.d/10-safespace.conf` (keys only, no root, group `wheel`, keys from `/etc/ssh/authorized_keys/%u`, host keys in `/var`); `sshd-hostkeys.service` + `sshd.service.d/10-hostkeys.conf` replace the masked `sshdgenkeys.service` |
| Network | `20-wired.network`: DHCP on physical ethernet only (`Kind=!*` skips Docker's veth pairs). The network variant configures the same thing once more in the initrd |
| sudo | `sudoers.d/10-wheel`: `wheel` without password |
| USB | `usbguard.service.d/10-early.conf`: usbguard starts before `sysinit.target` |
| Desktop | `tigervnc/vncserver-config-defaults` (XFCE, 1920x1080), `vncserver-config-mandatory` (`localhost` only) |
| Docker | `docker/daemon.json` (`data-root=/opt/docker/engine`, overlay2, no containerd image store); `containerd/config.toml` (root in `/opt/docker/containerd`); drop-ins for docker, docker.socket and containerd (`RequiresMountsFor=`/`ConditionPathIsMountPoint=/opt/docker`); `safespace-docker-images.service` + `load-docker-images` |
| Services | `system-preset/10-safespace.preset`: networkd, resolved, timesyncd, sshd, nftables, usbguard, `vncserver@:1`, var-factory, image loader (Docker is not enabled, see "Docker") |
| VM guest agent | `qemu/qemu-ga.conf`: `allow-rpcs=` reporting queries and `guest-shutdown` only; the agent starts via udev only in a VM with the agent channel |
| Sealing | `safespace-seal`, plus the keys exported by `secureboot-export.sh` |
| Locale | `etc/locale.gen` (en_US.UTF-8) |

### Tools around the build (not in the image)

`build.sh`, `secureboot-export.sh`, `burn.sh`, `diagnose.sh`, `netboot-export.sh`,
`test-vm.sh`, `hwtest-image.sh`, `update-snapshot.sh`, `fetch-images.sh`: see
"What's where".

## Living with a read-only, volatile system

| Topic | Behaviour |
|---|---|
| Configuration (`/etc`) | baked into the image; change `mkosi.extra/` or `mkosi.postinst` and rebuild |
| Users, ssh keys | created at build from `users.conf`; keys in the verified `/etc/ssh/authorized_keys/<user>` |
| Home directories | `/home` → `/var/home` in RAM, reset to the image's state on every boot (including XFCE settings) |
| **ssh host keys** | **new on every boot** (`/var` is RAM), so clients warn "host key changed" after each reboot. See "Open decisions" |
| Logs | journal in RAM only, gone after reboot |
| machine-id | new on every boot |
| Packages | no `pacman` on the running system; add to `Packages=` and rebuild |
| usbguard | only temporary `allow-device`; permanent rules go into the image |
| System extensions | `systemd-sysext`/`confext` stay disabled |
| RAM | `/var` (homes, logs, factory content) uses RAM; the factory part is small (users' homes, package database). The network variant also keeps the whole root image (~2 GiB) in RAM |

## What's where

| File | Purpose |
|---|---|
| `build.sh` | the build entry point: picks the variant (`usb` / `network`), fixes the version, puts the netboot URL on the signed command line, then runs mkosi |
| `mkosi.conf` | what both variants share: packages, kernel command line, UKI, Secure Boot key, verity, compression, caches |
| `repos.conf`, `repos.local.conf.example` | package source: `SNAPSHOT=` (date or `latest`) and `MIRROR=`; per-host override in `repos.local.conf` (gitignored); parsed by `lib/repos.sh` |
| `mkosi.profiles/usb/` | usb variant: `ImageId`, split artifacts, USB lockdown on the command line, USB/SD drivers, and `mkosi.repart/00-esp.conf` (the ESP) |
| `mkosi.profiles/network/` | network variant: `ImageId`, `SplitArtifacts=…,partitions`, `root=`/`systemd.verity=no`, ethernet drivers, initrd packages |
| `mkosi.repart/` | erofs root (verity data) and root-verity, for both variants |
| `mkosi.extra/` | files in the system: sshd, sudo, networkd, usbguard drop-in, TigerVNC, fstab, Docker and containerd config, guest agent restrictions, service presets, unit masks, volatile `/var`, image loader |
| `mkosi.initrd.conf/` | initrd configuration: unit masks for both, `mkosi.profiles/usb/` with `usb-bootdev`, `mkosi.profiles/network/` with `netroot` and the initrd network config |
| `mkosi.postinst` | `/home` and `/root` into `/var`, users and ssh keys, usbguard, VNC, sudoers check, mount points |
| `mkosi.finalize` | resolv.conf, moves the built `/var` to `/usr/share/factory/var` |
| `mkosi.postoutput` | UKI size and signature checks, netroot URL check (see above) |
| `docker-images.txt`, `fetch-images.sh` | images to ship and their downloader |
| `users.conf.example`, `safespace.env` | users and ssh keys (copy to `users.conf`); groups and VNC settings |
| `netboot.conf.example` | the netboot base URL for the network variant; copy to `netboot.conf` |
| `mkosi.local.conf.example` | per-host settings (erofs threads, key paths); copy to `mkosi.local.conf` |
| `burn.sh`, `diagnose.sh` | write a usb image (or `--netstick` a netstick image) to a medium; read-only check incl. `veritysetup verify` and which build is on it, for a netstick whether the server serves its root |
| `pxe-proxy.sh` | proxy DHCP + TFTP (dnsmasq) for UEFI PXE clients on an existing LAN, e.g. to test a machine without touching the LAN's DHCP server; logs to `mkosi.test/dnsmasq.log` |
| `netstick.sh` | a loader-only USB stick (signed systemd-boot + the published network UKI) for machines whose firmware cannot network-boot the UKI, e.g. the ThinkPad T450s ([NETBOOT.md](NETBOOT.md#machines-that-cannot-network-boot-the-uki-the-netstick)) |
| `lib/` | shared shell helpers: `repos.sh` (package source), `uefi.sh` (signer of EFI binaries), `keys.sh` (Secure Boot export and PCR signing key for a build) |
| `mkosi.profiles/debug/` | `./build.sh <variant> --debug`: ethtool, dmidecode, pciutils, kexec-tools, tcpdump, … on top of a variant; the version gets a `-debug` suffix |
| `netboot-export.sh` | the publish step for a network build (needed for real machines, not a test tool): verify UKI, root hash and root image against each other, write them as `boot.efi`/`root.img`/`root.verity` in `<tree>/<version>/`, move `current`, optionally rsync to the server, prune old versions |
| `NETBOOT.md` | the network variant end to end: trust model, a netboot server from scratch (dnsmasq + nginx), Secure Boot enrollment, rebuilding and rollout, QEMU test, troubleshooting |
| `test-vm.sh` | optional rehearsal in QEMU: boot an image as a USB stick, or `--netboot` a published network build (DHCP + HTTP boot, no disk), optionally with enforced Secure Boot, in Setup Mode or sealed |
| `hwtest-image.sh` | diagnostic stick for machines that reset/hang on the real stick: systemd-boot menu that starts the UKI layer by layer (see the script header) |
| `secureboot-export.sh` | public Secure Boot keys and signed enrollment updates for `safespace-seal`; run by `build.sh` before every build |
| `update-snapshot.sh` | moves the pinned package snapshot to the newest day |

## Everyday use

| Task | Command |
|---|---|
| Build | `sudo ./build.sh usb` or `sudo ./build.sh network` (`-f` to rebuild unchanged, `--workers N` erofs threads for this run) |
| Other mirror / newest packages | `SNAPSHOT=`/`MIRROR=` in `repos.local.conf` (["Package source"](#package-source-snapshot-and-mirror)) |
| Update packages | `./update-snapshot.sh && sudo ./build.sh <variant> -f` |
| Update shipped images | edit `docker-images.txt`, `./fetch-images.sh`, `sudo ./build.sh <variant> -f` |
| Force reinstalling all packages | `sudo ./build.sh <variant> -ff` |
| Show the resolved configuration | `./build.sh <variant> summary` |
| Look inside the image | `sudo mkosi --profile=<variant> shell` |
| Test in a VM (no root) | `./test-vm.sh` / `./test-vm.sh --secure-boot`, or `./test-vm.sh --netboot` (DHCP + HTTP boot, no disk; needs `qemu-desktop edk2-ovmf`, for Secure Boot `virt-firmware`) |
| Machine does not boot the stick | `./hwtest-image.sh`, write `mkosi.test/hwtest.img` with `dd`, try the menu entries in order |
| Burn / check (usb) | `sudo ./burn.sh /dev/sdX`, `sudo ./diagnose.sh /dev/sdX` |
| Debug build with diagnostic tools | `sudo ./build.sh <variant> --debug` |
| Netstick for a machine that cannot network-boot | `sudo ./netstick.sh --tree /srv/netboot/safespace`, then `dd` (the script prints the command) or `sudo ./burn.sh --netstick /dev/sdX` |
| Publish / roll out (network) | `./netboot-export.sh --rsync arch.boot.internal:/srv/netboot/safespace`, then boot the machine from the network (["Network boot: build and provide"](#network-boot-build-and-provide)) |
| Delete outputs / also caches | `sudo mkosi clean` / `sudo mkosi -ff clean` |

**Build host with many cores:** `cp mkosi.local.conf.example mkosi.local.conf` and set
`--workers=` to `nproc`, or pass `sudo ./build.sh <variant> --workers N` for one run
(`--workers` is a `build.sh` option, mkosi itself has none). Most of the build time goes into compressing the erofs root, which
uses 4 threads by default (`--workers=0` means single-threaded, not "all"). zstd for the
image and the initrd already uses all cores. The host needs the same tools as listed under
Quick start, plus the sbctl `db` key and certificate at the paths in `mkosi.conf` (or point
`SecureBootKey=`/`SecureBootCertificate=` elsewhere in `mkosi.local.conf`).

Caches: `mkosi.pkgcache/` (packages) and `mkosi.cache/` (installed system,
`Incremental=yes`). The cache skips package installation, not the erofs compression, which
runs on every build. After editing `Packages=`, build with `-ff` to be safe.

## Package source: snapshot and mirror

`build.sh` reads `repos.conf` (tracked, the project default) and then `repos.local.conf`
(gitignored, per host, `cp repos.local.conf.example repos.local.conf`); keys in the local file
win. Only `SNAPSHOT=` and `MIRROR=` are accepted, the files are parsed, not sourced. mkosi's
own `--mirror`/`--snapshot` are refused on the `build.sh` command line, so the files are the
only source. Before a build, `build.sh` fetches `core.db` from the resulting URL and stops
with the expected layout if it is not there.

`MIRROR=` is a base URL **without** `$repo/os/$arch`; mkosi appends the repository path:

| `SNAPSHOT=` | `MIRROR=` | URL mkosi uses per repository |
|---|---|---|
| `2026/10/17` | empty | `https://archive.archlinux.org/repos/2026/10/17/$repo/os/$arch` |
| `2026/10/17` | archive mirror `URL` | `URL/repos/2026/10/17/$repo/os/$arch` |
| `latest` | empty | `https://fastly.mirror.pkgbuild.com/$repo/os/$arch` |
| `latest` | pacman mirror `URL` | `URL/$repo/os/$arch` |

- A normal pacman mirror only works with `SNAPSHOT=latest`. Take its line from
  `/etc/pacman.d/mirrorlist` and drop `/$repo/os/$arch`:
  `Server = https://ftp.fau.de/archlinux/$repo/os/$arch` → `MIRROR=https://ftp.fau.de/archlinux`.
  `https://ftp.fau.de` alone misses the `/archlinux` directory; with `$repo/os/$arch` in it
  the path is doubled. With a date, a normal mirror fails because it has no `/repos/<date>/`.
- With a date, `MIRROR` has to be an Arch Linux Archive mirror (serves `/repos/YYYY/MM/DD/`
  and `/repos/last/lastsync`).
- `latest` pins nothing: mkosi reuses the incremental cache while the configuration is
  unchanged, so build with `-f` to get the current packages. Changing `SNAPSHOT` or `MIRROR`
  invalidates the incremental cache (both are part of mkosi's cache manifest);
  `mkosi.pkgcache/` is kept.
- `./update-snapshot.sh` sets `SNAPSHOT=` in `repos.conf` to the newest archive day (asked from
  `MIRROR`, else archive.archlinux.org); `latest` becomes a date again.
- Running `mkosi build` directly bypasses `build.sh` and installs from the current
  repositories (no snapshot); build with `build.sh`.

## Troubleshooting: the machine resets instead of booting

**Case found** (usb variant, one machine): the firmware reset without output when its boot
manager started the 90 MiB UKI directly as `\EFI\BOOT\BOOTX64.EFI`, but loaded the same
file when systemd-boot asked for it. Hence `Bootloader=systemd-boot` (a small signed
`BOOTX64.EFI`, the UKI in `\EFI\Linux\`, no `loader.conf`). Older builds also had 4K FAT
sectors and a CD boot header; both are fixed (`-S512`, `ElTorito=no`).

**If another machine doesn't boot:**

1. `sudo ./diagnose.sh /dev/sdX`: right build, 512-byte FAT, no ISO9660 header,
   systemd-boot as `BOOTX64.EFI`.
2. Note when it fails (immediately, after kernel messages, after 30-90 s), the Secure Boot
   state, and whether other live sticks boot.
3. `./hwtest-image.sh`: a stick with a menu that starts the UKI layer by layer; the script
   header says which result points to which layer. The test files are unsigned: Secure Boot
   off or in Setup Mode.

## USB lockdown

- `usbcore.authorized_default=0`: the kernel authorizes no USB device. Both variants.
- usb variant: in the initrd, `usb-bootdev` authorizes hubs and mass-storage interfaces, waits
  up to 30 s for the root partition (UUID derived from `roothash=`), revokes every USB device
  not on the path to it, and marks the medium read-only. A second stick posing as root is
  rejected by dm-verity.
- network variant: nothing authorizes anything, because nothing is needed from USB — every USB
  device stays unauthorized until usbguard is told otherwise (`sudo usbguard allow-device …`),
  and a USB NIC cannot be used for booting.
- After boot, usbguard blocks every new device. Log: `journalctl -b -g usb-bootdev` (usb) or
  `journalctl -b -g netroot` (network).

## Open decisions

- **ssh host keys.** With nothing writable on the stick, they're generated on every boot.
  Options:
  1. leave it like that, and connect with `StrictHostKeyChecking`/known_hosts relaxed for this
     host;
  2. bake fixed host keys into the image (every stick and every boot has the same key, but the
     private key is readable from the unencrypted stick);
  3. keep them on the data disk when present (stable per data disk, unverified storage);
  4. ssh host certificates from your own CA (`TrustedUserCAKeys`/`@cert-authority`), so clients
     trust any host key the CA signed. That needs the CA key at build time (option 2 plus a
     certificate) or a signing service.

## Known open points

- **Real hardware so far:** the usb variant on one machine; the network variant on a ThinkPad
  T450s over PXE (Intel AMT off). UEFI HTTP boot is tested in QEMU/libvirt only. Firmware
  differs (FAT handling, UKI size for network boot, option ROMs when sealing with
  `--replace`); `hwtest-image.sh` helps to find out why a machine doesn't boot.
- **Network variant limits:** the root image (~2 GiB) is downloaded into RAM on every boot;
  the server address is part of the signed command line (moving it means rebuilding); no
  boot while the server is down. See [NETBOOT.md](NETBOOT.md), "Known limits".
- **TPM:** old TPMs (e.g. the T450s' Intel PTT) fail the NvPCR units of systemd 262
  (`systemd-pcrnvdone` and friends); ignored, the system boots normally.
- `fetch-images.sh` is untested.
- **Still open from the security review:**
  - the UKI is signed with the build host's sbctl `db` key (a separate key for the sticks would
    be cleaner);
  - the build runs as root from a folder a normal user can write to;
  - old signed images stay bootable (network: for as long as their directory is on the
    server, which is also what makes a rollback work);
  - no kernel lockdown parameters.
- The data disk is unverified. Shipped images are reloaded when their ID doesn't match, but
  Docker doesn't re-check layer contents that are already on the disk.
- USB keyboards are blocked even at boot, and SD readers on USB with a vendor-specific interface
  (e.g. Realtek `rtsx_usb`) aren't authorized.
