#!/usr/bin/env bash
# Boot a usb build in QEMU as a USB stick (xHCI + usb-storage, like real
# hardware), with OVMF. The stick image is assembled from the build's parts
# (lib/stick.sh, as burn.sh writes a stick) and opened with snapshot=on.
#
#   ./test-vm.sh [SOURCE] [--secure-boot | --setup-mode | --sealed] [--ssh PORT]
#     SOURCE: a build (./build.sh list), a directory with the parts, or a
#     stick image file (.raw); default: the newest build
#   ./test-vm.sh --netboot [--tree DIR] [--tftp] [--secure-boot | ...] [--ssh PORT]
#   ./test-vm.sh --netboot --url BOOT_URL [--secure-boot | ...] [--ssh PORT]
#
# --netboot: a local netboot lab, no disk at all -- a rehearsal of the real
#   thing on this host. A real machine needs none of this: it is told to boot
#   from the network in its firmware and gets everything from the netboot
#   server (NETBOOT.md, "Boot a real machine").
#   The VM boots exactly the way such a machine does: DHCP hands it an address
#   and a boot file, the firmware downloads the signed UKI into memory and
#   starts it, and its initrd then loads the root image over HTTP.
#   QEMU's user network is the DHCP server here (that is what option
#   bootfile= sets), a local python HTTP server on 127.0.0.1 serves the
#   release (default mkosi.release/, written by release.sh), and the VM
#   reaches the host as 10.0.2.2 -- so the image has to be built for that
#   address:
#     sudo ./build.sh --url http://10.0.2.2:8000/ \
#          --kernel-command-line console=ttyS0,115200
#   (the console= part is optional and only makes the kernel and the netroot
#   messages show up in mkosi.test/serial.log, where this script looks for
#   them afterwards).
# --tftp: hand the UKI over QEMU's built-in TFTP server instead of HTTP, for
#   firmware without UEFI HTTP boot. The root image still comes over HTTP.
# --tree DIR: the release to serve (a directory with boot.efi, root.img,
#   root.verity, e.g. a distribution server's share).
# --url BOOT_URL: no local server; UEFI HTTP boot of a published UKI from a
#   distribution server, e.g. http://10.0.0.1/safespace/boot.efi.
#   The VM reaches it through QEMU's NAT and resolves names with the host's
#   DNS, so a normal build (netboot.conf URL) is tested as published, exactly
#   as a machine on the LAN would boot it.
#
# --secure-boot: enforced Secure Boot with only the UKI's own signing
#   certificate in db (taken from the signature, so no root needed). Needs
#   virt-fw-vars (pacman -S virt-firmware).
# --setup-mode: Secure Boot firmware with no keys (Setup Mode), as after
#   "Reset to Setup Mode". Run safespace-seal inside; the firmware variables
#   are kept in mkosi.test/sealed-vars.fd.
# --sealed: boot again with mkosi.test/sealed-vars.fd (after safespace-seal).
# --ssh PORT: forward localhost:PORT to the VM's sshd.
# Guest agent: the VM gets the qemu-ga channel, its socket is mkosi.test/qga.sock
#   (echo '{"execute":"guest-network-get-interfaces"}' | socat - UNIX-CONNECT:mkosi.test/qga.sock).
# Console: the QEMU window. A reset ends QEMU (-no-reboot) instead of looping.
# No root needed (user must be able to open /dev/kvm).
# Extra QEMU options via $QEMU_EXTRA, e.g. QEMU_EXTRA='-display none'.
set -Eeuo pipefail

HERE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
die() { printf '\e[1;31m==> ERROR:\e[0m %s\n' "$*" >&2; exit 1; }
log() { printf '\e[1;32m==>\e[0m %s\n' "$*"; }

IMAGE="" SB=0 SETUP=0 SEALED=0 SSH_PORT="" NETBOOT=0 TREE="" NBMODE=http BOOT_URL=""
while (($#)); do
	case $1 in
		--netboot) NETBOOT=1; shift ;;
		--tftp) NBMODE=tftp; shift ;;
		--tree) TREE=${2:?--tree needs a directory}; shift 2 ;;
		--url) BOOT_URL=${2:?--url needs the URL of boot.efi}; shift 2 ;;
		--secure-boot) SB=1; shift ;;
		--setup-mode) SETUP=1; shift ;;
		--sealed) SEALED=1; shift ;;
		--ssh) SSH_PORT=${2:?--ssh needs a port}; shift 2 ;;
		-h|--help) sed -n '2,${/^#/!q;s/^# \?//;p}' "$0"; exit 0 ;;
		-*) die "unknown option $1" ;;
		*) IMAGE=$1; shift ;;
	esac
done
OVMF=/usr/share/edk2/x64
[[ -f $OVMF/OVMF_CODE.4m.fd ]] || die "OVMF missing (pacman -S edk2-ovmf)"
WORK=$HERE/mkosi.test
mkdir -p "$WORK"

# RAM for the VM; MEM= in the environment overrides.
MEM=${MEM:-}
RAW=""
[[ -z $BOOT_URL ]] || ((NETBOOT)) || die "--url needs --netboot"
if ((NETBOOT)) && [[ -n $BOOT_URL ]]; then
	[[ -z $IMAGE && -z $TREE && $NBMODE == http ]] || die "--url takes no image, --tree or --tftp"
	[[ $BOOT_URL =~ ^https?://[^/]+/.+ ]] || die "--url needs a full http(s) URL of boot.efi: $BOOT_URL"
	# A local copy only to read the signed command line (and the signer for
	# --secure-boot); the VM downloads its own.
	uki=$WORK/remote-boot.efi
	curl -fsS -o "$uki" "$BOOT_URL" || die "cannot download $BOOT_URL"
	cmdline=$(objcopy -O binary --only-section=.cmdline "$uki" /dev/stdout 2>/dev/null | tr -d '\0')
	NETROOT_URL=$(tr ' ' '\n' <<<"$cmdline" | sed -n 's/^safespace.netroot=//p' | head -1)
	[[ -n $NETROOT_URL ]] || die "$BOOT_URL has no safespace.netroot= on its command line (built without NETROOT_URL)"
	# The largest root the VM might load: root.img, or one per combination.
	root_bytes=0
	for f in root.img $(tr ' ' '\n' <<<"$cmdline" | sed -n 's/^safespace\.root\.\([a-z0-9-]*\)=.*/root-\1.img/p'); do
		b=$(curl -fsSI "${NETROOT_URL%/}/$f" 2>/dev/null | tr -d '\r' | awk 'tolower($1) == "content-length:" { print $2 }')
		[[ $b =~ ^[0-9]+$ ]] && ((b > root_bytes)) && root_bytes=$b
	done
	((root_bytes > 0)) || die "the server serves no root image under ${NETROOT_URL%/}/"
	MEM=${MEM:-$((root_bytes / 1048576 + 2048))}
	log "UKI from $BOOT_URL, root from $NETROOT_URL"
elif ((NETBOOT)); then
	[[ -z $IMAGE ]] || die "--netboot takes no image (it boots the UKI from the netboot tree)"
	BOOTDIR=${TREE:-$HERE/mkosi.release}
	[[ -f $BOOTDIR/boot.efi ]] || die "no boot.efi in $BOOTDIR (run: ./release.sh)"
	uki=$BOOTDIR/boot.efi
	cmdline=$(objcopy -O binary --only-section=.cmdline "$uki" /dev/stdout 2>/dev/null | tr -d '\0')
	NETROOT_URL=$(tr ' ' '\n' <<<"$cmdline" | sed -n 's/^safespace.netroot=//p' | head -1)
	[[ -n $NETROOT_URL ]] || die "$uki has no safespace.netroot= on its command line (built without NETROOT_URL)"
	rest=${NETROOT_URL#*//}
	hostport=${rest%%/*}
	urlpath=${rest#*/}; urlpath=${urlpath%/}      # e.g. safespace, or empty
	[[ $rest == */* ]] || urlpath=""
	host=${hostport%%:*}; port=${hostport##*:}
	[[ $port == "$host" ]] && port=80
	[[ $host == 10.0.2.2 ]] ||
		die "this UKI loads its root from $host, which the VM cannot reach: QEMU's user network is the host at 10.0.2.2. Rebuild with: sudo ./build.sh network --url http://10.0.2.2:8000/"
	((port >= 1024)) || die "port $port would need root for the test server; rebuild with e.g. --url http://10.0.2.2:8000/"
	ls "$BOOTDIR"/root*.img >/dev/null 2>&1 || die "no root image in $BOOTDIR"
	# The root image is about as large as the system itself and is downloaded
	# into a tmpfs, so the VM needs the RAM for it (override with MEM=).
	root_mib=$(($(stat -c %s "$BOOTDIR"/root*.img | sort -n | tail -1) / 1048576))
	MEM=${MEM:-$((root_mib + 2048))}

	# Serve the published files under the exact path the signed URL names, so
	# the initrd finds them where it looks (a symlink farm, no copying).
	DOCROOT=$WORK/netboot-docroot
	rm -rf "$DOCROOT"
	if [[ -z $urlpath ]]; then
		ln -sfnT "$(readlink -f "$BOOTDIR")" "$DOCROOT"
	else
		mkdir -p "$DOCROOT/$(dirname "$urlpath")"
		ln -sfnT "$(readlink -f "$BOOTDIR")" "$DOCROOT/$urlpath"
	fi
	log "Serving $(readlink -f "$BOOTDIR") as http://10.0.2.2:$port/$urlpath/"
	python3 -m http.server "$port" --bind 127.0.0.1 --directory "$DOCROOT" &>"$WORK/http.log" &
	HTTP_PID=$!
	trap 'kill "$HTTP_PID" 2>/dev/null' EXIT
	sleep 0.3
	kill -0 "$HTTP_PID" 2>/dev/null || { cat "$WORK/http.log" >&2; die "the HTTP server did not start (port $port in use?)"; }
else
	MEM=${MEM:-2048}
	if [[ -f $IMAGE ]]; then
		RAW=$IMAGE
	else
		# shellcheck source=lib/stick.sh
		source "$HERE/lib/stick.sh"
		# shellcheck source=lib/builds.sh
		source "$HERE/lib/builds.sh"
		if [[ -d $IMAGE ]]; then
			SRC=$IMAGE
		elif [[ -n $IMAGE ]]; then
			SRC=$(builds_dir "$(builds_find "$IMAGE")")
		else
			b=$(builds_newest)
			[[ -n $b ]] || die "no build (run: sudo ./build.sh)"
			SRC=$(builds_dir "$b")
		fi
		[[ -f $SRC/layout.sfdisk ]] || die "$SRC is not a build (or one from before the single build)"
		RAW=$WORK/stick.raw
		log "Assembling the stick image from $SRC"
		stick_write "$RAW" "$SRC"
	fi
fi

machine=q35,accel=kvm
code=$OVMF/OVMF_CODE.4m.fd
vars=$WORK/vars.fd
cp "$OVMF/OVMF_VARS.4m.fd" "$vars"
extra=()
if ((SB)); then
	command -v virt-fw-vars >/dev/null || die "virt-fw-vars missing (pacman -S virt-firmware)"
	if ((!NETBOOT)); then
		uki=$WORK/uki.efi
		mcopy -n -i "$RAW@@$(($(sfdisk -d "$RAW" | awk -F'[=,]' '/type=C12A7328/ { print $2 }') * 512))" \
			::/EFI/BOOT/BOOTX64.EFI "$uki" 2>/dev/null || die "cannot read the UKI from the ESP (mtools installed?)"
	fi
	# Certificate table (PE data directory 4) -> PKCS#7 -> signer certificate.
	python3 -I - "$uki" "$WORK/sig.p7" <<-'EOF'
		import struct, sys
		d = open(sys.argv[1], 'rb').read()
		opt = struct.unpack_from('<I', d, 0x3c)[0] + 24
		dd = opt + (112 if struct.unpack_from('<H', d, opt)[0] == 0x20b else 96)
		off, size = struct.unpack_from('<II', d, dd + 32)
		if not size: sys.exit('UKI is not signed')
		length = struct.unpack_from('<I', d, off)[0]
		open(sys.argv[2], 'wb').write(d[off + 8:off + length])
	EOF
	openssl pkcs7 -inform DER -in "$WORK/sig.p7" -print_certs -out "$WORK/db.pem"
	log "Secure Boot with db = $(openssl x509 -in "$WORK/db.pem" -noout -subject)"
	guid=$(cat /proc/sys/kernel/random/uuid)
	virt-fw-vars -i "$OVMF/OVMF_VARS.4m.fd" -o "$vars" --secure-boot \
		--set-pk "$guid" "$WORK/db.pem" --add-kek "$guid" "$WORK/db.pem" --add-db "$guid" "$WORK/db.pem" >/dev/null 2>&1
	machine+=,smm=on
	code=$OVMF/OVMF_CODE.secboot.4m.fd
	extra+=(-global driver=cfi.pflash01,property=secure,value=on)
fi
if ((SETUP || SEALED)); then
	vars=$WORK/sealed-vars.fd
	if ((SETUP)); then
		cp "$OVMF/OVMF_VARS.4m.fd" "$vars"
		log "Setup Mode: no Secure Boot keys enrolled (run safespace-seal in the VM)"
	else
		[[ -f $vars ]] || die "no $vars (run --setup-mode and safespace-seal first)"
		log "Using the firmware variables written by safespace-seal"
	fi
	machine+=,smm=on
	code=$OVMF/OVMF_CODE.secboot.4m.fd
	extra+=(-global driver=cfi.pflash01,property=secure,value=on)
fi
nic=user,model=virtio-net-pci
[[ -n $SSH_PORT ]] && nic+=,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22

boot=()
if ((NETBOOT)); then
	# DHCP (QEMU's user network) tells the firmware what to boot; -boot order=n
	# makes the firmware's network boot option the first one.
	# HTTP boot: no PXE boot entries in OVMF, which would otherwise be tried
	# first and fail on the URL.
	[[ $NBMODE == http ]] && extra+=(
		-fw_cfg name=opt/org.tianocore/IPv4PXESupport,string=n
		-fw_cfg name=opt/org.tianocore/IPv6PXESupport,string=n
	)
	if [[ -n $BOOT_URL ]]; then
		nic+=",bootfile=$BOOT_URL"
	elif [[ $NBMODE == http ]]; then
		# UEFI HTTP boot: the boot file is a URL, the firmware downloads it
		# itself. This is what a machine on a real network does.
		nic+=",bootfile=http://10.0.2.2:$port/${urlpath:+$urlpath/}boot.efi"
	else
		nic+=",tftp=$(readlink -f "$BOOTDIR"),bootfile=boot.efi"
	fi
	boot=(-boot order=n)
	log "Netbooting over ${NBMODE^^} with ${MEM} MiB RAM (close the window to stop)"
else
	boot=(
		-device qemu-xhci,id=xhci
		-drive if=none,id=stick,format=raw,file="$RAW",snapshot=on
		-device usb-storage,bus=xhci.0,drive=stick,removable=on
	)
	log "Booting $(basename "$RAW") as a USB stick (close the window to stop)"
fi
qemu-system-x86_64 -machine "$machine" "${extra[@]}" -cpu host -smp 2 -m "$MEM" \
	-drive if=pflash,format=raw,readonly=on,file="$code" \
	-drive if=pflash,format=raw,file="$vars" \
	"${boot[@]}" \
	-nic "$nic" \
	-device virtio-serial -chardev socket,id=qga,path="$WORK/qga.sock",server=on,wait=off \
	-device virtserialport,chardev=qga,name=org.qemu.guest_agent.0 \
	-serial file:"$WORK/serial.log" \
	-no-reboot ${QEMU_EXTRA:-} && rc=0 || rc=$?
log "QEMU exited ($rc). Firmware/serial output: $WORK/serial.log"

if ((NETBOOT)); then
	# What of the chain shows up in the serial log. The firmware always logs
	# there; the kernel and the netroot messages only if the image was built
	# with console=ttyS0,115200 on its command line.
	s=$(tr -d '\000' <"$WORK/serial.log" 2>/dev/null || true)
	step() { # label regex
		if grep -qaE "$2" <<<"$s"; then printf '  \e[32mOK\e[0m   %s\n' "$1"; else printf '  \e[33m--\e[0m   %s\n' "$1"; fi
	}
	log "Boot chain:"
	step "firmware: DHCP address and boot file" 'Start (PXE|HTTP) over IPv4|Station IP address'
	step "firmware: UKI downloaded and started" 'NBP file downloaded successfully|Downloading\.\.\.100%|starting Boot[0-9]+ "UEFI (PXEv4|HTTPv4)'
	step "UKI started, initrd running" 'Booting initrd|Expecting device /dev/mapper/root|netroot:'
	step "initrd: netroot waited for DHCP" 'netroot: waiting|netroot: link up'
	step "initrd: root.img downloaded" 'netroot: got root.img'
	step "initrd: dm-verity root opened" 'netroot: root opened as'
	step "root mounted, system started" 'Mounted /sysroot|Startup finished|login:'
	grep -qa 'netroot:' <<<"$s" ||
		log "  nothing from the image itself in the log: build it with --kernel-command-line console=ttyS0,115200 to see the kernel and netroot messages here (otherwise watch the QEMU window)"
	printf '  HTTP requests the VM made:\n'
	grep -aoE '"GET [^"]*"' "$WORK/http.log" 2>/dev/null | sort -u | sed 's/^/       /' || true
fi
