#!/usr/bin/env bash
# Answer UEFI PXE clients on an existing LAN without touching its DHCP server:
# dnsmasq as proxy DHCP (the LAN's own server keeps handing out addresses)
# plus TFTP for the boot file. For tests and for machines without UEFI HTTP
# boot; see NETBOOT.md, "Quick one-off test on an existing LAN".
#
#   sudo ./pxe-proxy.sh BOOTFILE [--root DIR] [--interface IF] [--subnet NET]
#
#   BOOTFILE        path of the boot file below the TFTP root, e.g.
#                   safespace/current/boot.efi
#   --root DIR      TFTP root (default: /srv/netboot, the server tree's parent)
#   --interface IF  interface to answer on (default: the default route's)
#   --subnet NET    the LAN's network address (default: IF's IPv4 network)
#
# Only x86-64 UEFI clients (client-arch 7 and 9) get an answer. Everything
# runs in the foreground; DHCP and TFTP details are logged to the terminal and
# appended to mkosi.test/dnsmasq.log. Stop with Ctrl-C.
# A firewall in between must pass UDP 67 and 4011 (proxy DHCP) and UDP 69
# (TFTP; all of it, thanks to --tftp-single-port). Proxy DHCP only sees
# clients on the same L2 segment.
set -Eeuo pipefail

HERE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
log() { printf '\e[1;32m==>\e[0m %s\n' "$*"; }
die() { printf '\e[1;31m==> ERROR:\e[0m %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,${/^#/!q;s/^# \?//;p}' "$0"; }

ROOT=/srv/netboot IFACE="" SUBNET="" BOOTFILE=""
while (($#)); do
	case $1 in
		--root) ROOT=${2:?--root needs a directory}; shift 2 ;;
		--interface) IFACE=${2:?--interface needs a name}; shift 2 ;;
		--subnet) SUBNET=${2:?--subnet needs a network address}; shift 2 ;;
		-h | --help) usage; exit 0 ;;
		-*) usage >&2; die "unknown option $1" ;;
		*) [[ -z $BOOTFILE ]] || die "only one BOOTFILE"; BOOTFILE=$1; shift ;;
	esac
done

[[ -n $BOOTFILE ]] || { usage >&2; die "BOOTFILE missing"; }
[[ $BOOTFILE =~ ^[A-Za-z0-9._/-]+$ && $BOOTFILE != /* && /$BOOTFILE/ != */../* ]] ||
	die "BOOTFILE must be a plain relative path below the TFTP root: $BOOTFILE"
[[ $EUID -eq 0 ]] || die "must run as root (DHCP and TFTP ports)"
command -v dnsmasq >/dev/null || die "dnsmasq missing (pacman -S dnsmasq)"
ROOT=$(readlink -f "$ROOT")
[[ -f $ROOT/$BOOTFILE ]] || die "no $ROOT/$BOOTFILE"

[[ -n $IFACE ]] || IFACE=$(ip -4 route show default | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }')
[[ -n $IFACE ]] || die "no default route: pass --interface"
ip link show "$IFACE" >/dev/null 2>&1 || die "no interface $IFACE"
if [[ -z $SUBNET ]]; then
	cidr=$(ip -4 -o addr show dev "$IFACE" | awk '{ print $4; exit }')
	[[ -n $cidr ]] || die "$IFACE has no IPv4 address: pass --subnet"
	SUBNET=$(python3 -I -c 'import ipaddress, sys; print(ipaddress.ip_interface(sys.argv[1]).network.network_address)' "$cidr")
fi
[[ $SUBNET =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "invalid subnet $SUBNET"

LOG=$HERE/mkosi.test/dnsmasq.log
mkdir -p "$(dirname "$LOG")"
log "Proxy DHCP on $IFACE ($SUBNET), TFTP root $ROOT"
log "Boot file: $BOOTFILE ($(($(stat -c %s "$ROOT/$BOOTFILE") / 1024)) KiB)"
log "Log: $LOG"
printf '\n===== %s pxe-proxy %s =====\n' "$(date '+%F %T')" "$BOOTFILE" >>"$LOG"
exec > >(tee -a "$LOG") 2>&1
exec dnsmasq --no-daemon --port=0 --interface="$IFACE" \
	--dhcp-range="$SUBNET,proxy" \
	--dhcp-match=set:efi64,option:client-arch,7 \
	--dhcp-match=set:efi64,option:client-arch,9 \
	"--pxe-service=tag:efi64,x86-64_EFI,safespace netboot,$BOOTFILE" \
	--enable-tftp --tftp-root="$ROOT" --tftp-single-port \
	--log-dhcp
