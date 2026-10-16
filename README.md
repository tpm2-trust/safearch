# safespace-arch with mkosi

A Secure-Boot-signed Arch Linux system for USB sticks and SD cards, built with
[mkosi](https://github.com/systemd/mkosi) (written for mkosi 27). The system is
**read-only**: the stick is never written to at runtime. The root is protected by
dm-verity, `/var` lives in RAM, and only disks mounted at runtime are writable. Docker
images travel on the stick; Docker's storage lives on a data disk at `/opt/docker`.
An XFCE desktop is available over VNC (through an ssh tunnel).

> **Status:** tested in QEMU (OVMF, stick on emulated USB): boots with and without enforced
> Secure Boot; dm-verity verified, stick read-only at block level; sealing with
> `safespace-seal` (append and `--replace`) and booting the sealed VM. Boots on one real
> machine (Secure Boot in Setup Mode).

## Quick start

```sh
# once: host tools
sudo pacman -S --needed mkosi systemd-ukify sbctl efitools dosfstools mtools erofs-utils zstd skopeo
sudo sbctl create-keys        # if you have no Secure Boot keys yet (/var/lib/sbctl)

cp users.conf.example users.conf   # add your users and ssh keys
# optional: safespace.env (VNC), docker-images.txt (images to ship)
sudo ./secureboot-export.sh   # public keys for safespace-seal (see "Sealing")
./fetch-images.sh             # downloads the listed images (skip if none)
sudo mkosi build              # -> mkosi.output/safespace-arch_<date-time>.raw.zst
sudo ./burn.sh /dev/sdX       # writes the newest image to the stick
sudo ./diagnose.sh /dev/sdX   # optional: verifies root on the stick block by block

# on the machine, once per data disk (any disk except the stick):
sudo mkfs.ext4 -L safespace-docker /dev/<datadisk>
```

`sudo mkosi build` is needed because the signing key in `/var/lib/sbctl/keys/db/` is
readable by root only.

Not tracked by git, created per user or host: `users.conf`, `mkosi.local.conf`, the exported
keys (`mkosi.extra/usr/share/safespace/secureboot/`), shipped images
(`mkosi.extra/usr/share/safespace/docker-images/`), caches and outputs.

## The stick is never written to

| Layer | How |
|---|---|
| Partitions | only ESP, root and root-verity. No writable partition, no growing |
| Root (`/usr` and `/etc`) | erofs (read-only filesystem) on dm-verity. The root hash is part of the signed kernel command line, so any changed block fails to read |
| `/var` | tmpfs (`systemd.volatile=state`), filled on every boot from the verified copy in `/usr/share/factory/var` (`safespace-var-factory.service`). Everything written there is gone after reboot |
| ESP | never mounted (`efi`/`boot` mounts masked); no `loader/random-seed` on it, so systemd-boot writes nothing; `systemd-boot-update`, `systemd-boot-random-seed` and systemd-repart are masked |
| Block level | after finding root, the initrd step `usb-bootdev` runs `blockdev --setro` on the stick and all its partitions, so the kernel refuses writes to it, even from root |

Writable storage exists only on disks mounted at runtime, such as the Docker data disk.

| # | Partition | Content |
|---|---|---|
| 1 | ESP, 512 MiB, FAT | signed systemd-boot `\EFI\BOOT\BOOTX64.EFI`, signed UKI `\EFI\Linux\*.efi` |
| 2 | root, erofs (zstd) | `/usr`, `/etc`, factory `/var`, shipped Docker images |
| 3 | root-verity | dm-verity hash tree for partition 2 |

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
3. The initrd (also signed) reads `roothash=`, finds the root and hash partitions by the UUIDs
   derived from it, and sets up `/dev/mapper/root`.
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
systemd-boot and the UKI.

**Preconditions:** Secure Boot on and a firmware password on every machine. Without Secure Boot,
any command line (and with it any `roothash=`) can be passed in. The `db` key decides
everything: whoever has it can sign a UKI for a manipulated root.

## Sealing a machine to these keys

The stick can enroll its own Secure Boot keys on a machine, so that the machine afterwards
only boots binaries signed with them (the "seal").

**On the build host, once (and after every key rotation):**

```sh
sudo ./secureboot-export.sh      # reads /var/lib/sbctl, writes public files only
sudo mkosi -f build
```

`secureboot-export.sh` puts into `mkosi.extra/usr/share/safespace/secureboot/` the PK, KEK
and db certificates and the signed updates (`*.auth`) the firmware needs to enroll them. The
private keys are only used to sign those updates (PK signs PK and KEK, KEK signs db) and stay
in `/var/lib/sbctl`. The build fails if the UKI is signed by a different key than the shipped
`db.pem`, because a machine sealed from that stick would refuse to boot it. Without the export
the build still works; `safespace-seal` then refuses to run.

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

## Docker

**Why a data disk is needed:** Docker can't run from read-only storage. Its storage
(`data-root`) is constantly written: layer metadata, image references, container layers,
volumes, networks. RAM (`/var`) would fill up quickly. So:

- `/etc/docker/daemon.json`: `data-root` is `/opt/docker/engine`, storage driver `overlay2`.
  Docker 29's default containerd image store is switched off on purpose, so all images live
  in `data-root` and image IDs can be checked against the shipped archives.
- `/etc/containerd/config.toml`: containerd's data goes to `/opt/docker/containerd`.
- `docker.service`, `docker.socket` and `containerd.service` only start when `/opt/docker`
  is a mount point (`ConditionPathIsMountPoint`). Without the disk, Docker stays off
  instead of failing on the read-only root or filling RAM.
- `/etc/fstab` mounts a disk labelled **`safespace-docker`** at `/opt/docker` if present at boot
  (`nofail`, 10 s timeout). The filesystem must support overlay2: ext4, xfs with ftype=1, or
  btrfs.
- Attached later: `sudo mount /dev/<datadisk> /opt/docker && sudo systemctl start docker`.

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

### Build configuration (`mkosi.conf`, `mkosi.conf.d/`)

| Setting | Why |
|---|---|
| `Format=disk`, `Bootable=yes` | bootable GPT image |
| `Bootloader=systemd-boot` | mkosi's default for this setup would be a bare UKI as `\EFI\BOOT\BOOTX64.EFI`. Some firmware resets when its boot manager starts a 90 MiB UKI directly, but loads it fine for systemd-boot (see "Troubleshooting") |
| `ElTorito=no` | mkosi 27 adds an ISO9660/El Torito header for CD boot by default; a stick boots via GPT |
| `SecureBoot=yes`, `SecureBootKey`/`Certificate` from `/var/lib/sbctl`, `SecureBootSignTool=systemd-sbsign`, `SecureBootAutoEnroll=no` | systemd-boot and the UKI are signed with the sbctl `db` key; no systemd-boot auto-enrollment files on the ESP (`safespace-seal` does enrollment) |
| `Verity=hash` | dm-verity root; the root hash is on the signed kernel command line, no signature partition needed |
| `SplitArtifacts=uki,roothash`, `ManifestFormat=json` | UKI, root hash and package list next to the image |
| `CompressOutput=zstd`, `CompressLevel=10` | image as `.raw.zst`, only as large as its content |
| `OutputDirectory=mkosi.output` | outputs out of the project root |
| `Snapshot=` in `mkosi.conf.d/20-snapshot.conf` | pinned Arch Linux Archive day: rebuilds install the same packages; `update-snapshot.sh` moves it |
| `Incremental=yes`, `CacheDirectory=`, `PackageCacheDirectory=` | two cache levels: downloaded packages and the installed system |
| `Environment=SYSTEMD_REPART_MKFS_OPTIONS_VFAT=-S512` | FAT with 512-byte sectors (many firmwares don't read 4K-sector FAT on USB), while erofs and verity keep 4K blocks |
| `Ssh=never` | no sshd-over-vsock units for `mkosi vm` |
| `Hostname=`, `Locale=`, `Keymap=`, `Timezone=` | safespace, en_US.UTF-8, us, UTC |
| `mkosi.version` | `ImageVersion` is the build timestamp, so every build gets its own files |
| `mkosi.local.conf.example` | per-host settings, e.g. more erofs compression threads |

### Disk layout (`mkosi.repart/`)

| File | Partition |
|---|---|
| `00-esp.conf` | 512 MiB FAT32 with systemd-boot and the UKI only. Excluded: `intel-ucode.img` (the UKI has its microcode), `loader/` (no loader.conf, no type 1 entries, no random seed), `\EFI\systemd\` (only needed for NVRAM boot entries), `BOOTIA32.EFI` |
| `10-root.conf` | erofs, zstd level 12, `Minimize=best`; without `/var`, `/efi`, `/boot` |
| `11-root-verity.conf` | dm-verity hash tree for root |

### Kernel command line (`KernelCommandLine=`, signed into the UKI)

| Option | Effect |
|---|---|
| `systemd.volatile=state` | `/var` is a tmpfs |
| `usbcore.authorized_default=0` | the kernel authorizes no USB device by itself |
| `systemd.credentials_boot_policy=strict` | no null-key credentials from the ESP |
| `systemd.sysext=0`, `systemd.confext=0`, `rd.systemd.sysext=0`, `rd.systemd.confext=0` | no extension images over `/usr` and `/etc` |
| `systemd.verity_root_options=panic-on-corruption` | a modified root block stops the system |
| `systemd.firstboot=off` | no first-boot questions |

### Initrd (`mkosi.initrd.conf/`, `InitrdPackages=`, `KernelInitrdModules=`)

- Extra drivers for USB storage, MMC and card readers; `coreutils`, `sed`, `kmod` for the
  script below.
- `usb-bootdev.service` and `/usr/local/lib/safespace/usb-bootdev`: see "USB lockdown".
- sysext/confext units masked in the initrd as well.
- `CompressLevel=19`, and unused sqlite tools and `magic.mgc` removed, to keep the UKI small.

### Build scripts

| Script | What it does |
|---|---|
| `mkosi.postinst` | users from `users.conf` without password (`*`) and with groups from `safespace.env`; their ssh keys into the read-only `/etc/ssh/authorized_keys/<user>`; root locked; `/home` → `/var/home`, `/root` → `/var/roothome`; sudoers check; usbguard daemon settings (block new devices, keep present ones, IPC for `wheel`); VNC password (random per build, saved next to the image); mount points `/efi`, `/var`, `/opt/docker` |
| `mkosi.finalize` | `resolv.conf` → systemd-resolved stub; moves the built `/var` to `/usr/share/factory/var` (caches and logs dropped) |
| `mkosi.postoutput` | fails the build if the UKI is larger than 100 MiB, or signed by another key than the exported `db.pem` |

### Files in the system (`mkosi.extra/`)

| Area | Files |
|---|---|
| Read-only system | `etc/fstab` (ESP never mounted, Docker data disk); `safespace-var-factory.service` fills `/var` from the factory copy on every boot; masked: `boot.mount`, `boot.automount`, `efi.mount`, `efi.automount`, `systemd-repart`, `systemd-boot-random-seed`, `systemd-boot-update`, all sysext/confext units |
| ssh | `sshd_config.d/10-safespace.conf` (keys only, no root, group `wheel`, keys from `/etc/ssh/authorized_keys/%u`, host keys in `/var`); `sshd-hostkeys.service` + `sshd.service.d/10-hostkeys.conf` replace the masked `sshdgenkeys.service` |
| Network | `20-wired.network`: DHCP on physical ethernet only (`Kind=!*` skips Docker's veth pairs) |
| sudo | `sudoers.d/10-wheel`: `wheel` without password |
| USB | `usbguard.service.d/10-early.conf`: usbguard starts before `sysinit.target` |
| Desktop | `tigervnc/vncserver-config-defaults` (XFCE, 1920x1080), `vncserver-config-mandatory` (`localhost` only) |
| Docker | `docker/daemon.json` (`data-root=/opt/docker/engine`, overlay2, no containerd image store); `containerd/config.toml` (root in `/opt/docker/containerd`); drop-ins for docker, docker.socket and containerd (`RequiresMountsFor=`/`ConditionPathIsMountPoint=/opt/docker`); `safespace-docker-images.service` + `load-docker-images` |
| Services | `system-preset/10-safespace.preset`: networkd, resolved, timesyncd, sshd, nftables, docker, usbguard, `vncserver@:1`, var-factory, image loader |
| Sealing | `safespace-seal`, plus the keys exported by `secureboot-export.sh` |
| Locale | `etc/locale.gen` (en_US.UTF-8) |

### Tools around the build (not in the image)

`secureboot-export.sh`, `burn.sh`, `diagnose.sh`, `test-vm.sh`, `hwtest-image.sh`,
`update-snapshot.sh`, `fetch-images.sh`: see "What's where".

## Living with a read-only, volatile system

| Topic | Behaviour |
|---|---|
| Configuration (`/etc`) | baked into the image; change `mkosi.extra/` or `mkosi.postinst` and rebuild |
| Users, ssh keys | created at build from `users.conf`; keys in the verified `/etc/ssh/authorized_keys/<user>` |
| Home directories | `/home` → `/var/home` in RAM, reset to the image's state on every boot (including XFCE settings) |
| **ssh host keys** | **new on every boot** (`/var` is RAM), so clients warn "host key changed" after each reboot. See "Open decisions" |
| Logs | journal in RAM only, gone after reboot |
| machine-id | new on every boot |
| Packages | no `pacman` on the stick; add to `Packages=` and rebuild |
| usbguard | only temporary `allow-device`; permanent rules go into the image |
| System extensions | `systemd-sysext`/`confext` stay disabled |
| RAM | `/var` (homes, logs, factory content) uses RAM; the factory part is small (users' homes, package database) |

## What's where

| File | Purpose |
|---|---|
| `mkosi.conf` | packages, kernel command line, UKI, Secure Boot key, verity, compression, caches |
| `mkosi.conf.d/20-snapshot.conf` | pinned Arch Linux Archive snapshot; `update-snapshot.sh` moves it |
| `mkosi.repart/` | ESP, erofs root (verity data), root-verity |
| `mkosi.extra/` | files in the system: sshd, sudo, networkd, usbguard drop-in, TigerVNC, fstab, Docker and containerd config, service presets, unit masks, volatile `/var`, image loader |
| `mkosi.initrd.conf/` | the `usb-bootdev` service and script for mkosi's default initrd |
| `mkosi.postinst` | `/home` and `/root` into `/var`, users and ssh keys, usbguard, VNC, sudoers check, mount points |
| `mkosi.finalize` | resolv.conf, moves the built `/var` to `/usr/share/factory/var` |
| `mkosi.postoutput` | fails the build if the UKI is larger than 100 MiB or not signed by the exported `db.pem` |
| `docker-images.txt`, `fetch-images.sh` | images to ship and their downloader |
| `users.conf.example`, `safespace.env` | users and ssh keys (copy to `users.conf`); groups and VNC settings |
| `mkosi.local.conf.example` | per-host settings (erofs threads, key paths); copy to `mkosi.local.conf` |
| `burn.sh`, `diagnose.sh` | write an image to a stick; read-only check incl. `veritysetup verify` and which build is on the stick |
| `test-vm.sh` | boot an image in QEMU as a USB stick, optionally with enforced Secure Boot, in Setup Mode or sealed |
| `hwtest-image.sh` | diagnostic stick for machines that reset/hang on the real stick: systemd-boot menu that starts the UKI layer by layer (see the script header) |
| `secureboot-export.sh` | public Secure Boot keys and signed enrollment updates for `safespace-seal` |
| `update-snapshot.sh` | moves the pinned package snapshot to the newest day |

## Everyday use

| Task | Command |
|---|---|
| Build | `sudo mkosi build` (`-f` to rebuild unchanged) |
| Update packages | `./update-snapshot.sh && sudo mkosi -f build` |
| Update shipped images | edit `docker-images.txt`, `./fetch-images.sh`, `sudo mkosi -f build` |
| Force reinstalling all packages | `sudo mkosi -ff build` |
| Show the resolved configuration | `mkosi summary` |
| Look inside the image | `sudo mkosi shell` |
| Test in a VM (no root) | `./test-vm.sh` or `./test-vm.sh --secure-boot` (needs `qemu-desktop edk2-ovmf`, for Secure Boot `virt-firmware`) |
| Machine does not boot the stick | `./hwtest-image.sh`, write `mkosi.test/hwtest.img` with `dd`, try the menu entries in order |
| Burn / check | `sudo ./burn.sh /dev/sdX`, `sudo ./diagnose.sh /dev/sdX` |
| Delete outputs / also caches | `sudo mkosi clean` / `sudo mkosi -ff clean` |

**Build host with many cores:** `cp mkosi.local.conf.example mkosi.local.conf` and set
`--workers=` to `nproc`. Most of the build time goes into compressing the erofs root, which
uses 4 threads by default (`--workers=0` means single-threaded, not "all"). zstd for the
image and the initrd already uses all cores. The host needs the same tools as listed under
Quick start, plus the sbctl `db` key and certificate at the paths in `mkosi.conf` (or point
`SecureBootKey=`/`SecureBootCertificate=` elsewhere in `mkosi.local.conf`).

Caches: `mkosi.pkgcache/` (packages) and `mkosi.cache/` (installed system,
`Incremental=yes`). The cache skips package installation, not the erofs compression, which
runs on every build. After editing `Packages=`, build with `-ff` to be safe.

## Troubleshooting: the machine resets instead of booting

**Case found so far** (one real machine, Secure Boot in Setup Mode): right after selecting the
stick, the machine reset without any output. The same image booted in QEMU, and an Arch ISO
booted from the same port.

How it was narrowed down:

1. **Is the right image on the stick?** `diagnose.sh` shows the build on the stick (root hash vs.
   `mkosi.output/*.roothash`). The first attempt had an older build burned, with 4K FAT
   sectors and a CD boot header; both are fixed in the build now (`-S512`, `ElTorito=no`).
2. **Diagnostic stick.** `./hwtest-image.sh` builds a stick with a systemd-boot menu that starts
   the same UKI layer by layer: the full UKI, the UKI without microcode, systemd-stub with the
   kernel only, the kernel without stub, the kernel with initrd, with and without microcode.
   **All entries booted**, including the unmodified UKI.
3. **Compare the sticks.** Both FAT filesystems were identical apart from the label
   (FAT32, 512-byte sectors, same geometry). The only difference left: on the real stick, the
   firmware's boot manager started the 90 MiB UKI directly as `\EFI\BOOT\BOOTX64.EFI`; on
   the diagnostic stick, systemd-boot (130 KiB) was `BOOTX64.EFI` and loaded the UKI.

**Finding:** this firmware resets when its boot manager starts a 90 MiB UKI as
`BOOTX64.EFI`, but loads the same file fine when systemd-boot asks for it. Hence
`Bootloader=systemd-boot`: a small signed systemd-boot as `BOOTX64.EFI`, the UKI in
`\EFI\Linux\`, no `loader.conf` (boots the only UKI immediately). With that, the stick boots
on that machine.

**If another machine doesn't boot:**

1. `sudo ./diagnose.sh /dev/sdX`: right build, 512-byte FAT, no ISO9660 header,
   systemd-boot as `BOOTX64.EFI`.
2. Note when it fails (immediately without output, after kernel messages, after 30-90 s),
   the Secure Boot state, and whether other live sticks boot.
3. `./hwtest-image.sh`, then write the image (the script prints the `dd` command), try entries
   1-6 and note which ones fail. Entries 3-6 print kernel messages from the start, so a crash
   shows how far it got. The test files are unsigned: Secure Boot must be off or in Setup Mode.

| Result | Points to |
|---|---|
| no menu at all | firmware can't start anything from this layout (partition table, FAT) |
| 4 fails | kernel |
| 4 boots, 3 fails | systemd-stub |
| 5 boots, 6 fails / 2 boots, 1 fails | microcode |
| 3 and 4 boot, 1/2/5/6 fail | initrd size or content |
| all boot, real stick doesn't | how the firmware starts the real ESP's `BOOTX64.EFI` (the case above) |

## USB lockdown

- `usbcore.authorized_default=0`: the kernel authorizes no USB device.
- In the initrd, `usb-bootdev` authorizes hubs and mass-storage interfaces, waits up to 30 s for
  the root partition (UUID derived from `roothash=`), revokes every USB device not on the path
  to it, and marks the stick read-only. A second stick posing as root is rejected by dm-verity.
- After boot, usbguard blocks every new device. Log: `journalctl -b -g usb-bootdev`.

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

- **Tested on one real machine only.** Firmware differs (FAT handling, UKI loading, option
  ROMs when sealing with `--replace`); `hwtest-image.sh` helps to find out why a machine
  doesn't boot.
- `fetch-images.sh` is untested.
- Without a data disk, the console shows "Dependency failed" for docker.socket,
  docker.service, containerd and the image loader. That's expected: they hard-require the
  `/opt/docker` mount, which fails after 10 s without the disk. No unit ends up failed.
- **Still open from the security review:**
  - the UKI is signed with the build host's sbctl `db` key (a separate key for the sticks would
    be cleaner);
  - the build runs as root from a folder a normal user can write to;
  - old signed images stay bootable;
  - no kernel lockdown parameters.
- The data disk is unverified. Shipped images are reloaded when their ID doesn't match, but
  Docker doesn't re-check layer contents that are already on the disk.
- USB keyboards are blocked even at boot, and SD readers on USB with a vendor-specific interface
  (e.g. Realtek `rtsx_usb`) aren't authorized.
