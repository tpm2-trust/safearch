#!/usr/bin/env bash
# Build one of the two safespace-arch variants with mkosi.
#
#   sudo ./build.sh usb     [--groups LIST] [--workers N] [--debug] [MKOSI OPTIONS...]
#   sudo ./build.sh network [--groups LIST] [--url BASE_URL]... [--workers N] [--debug] [MKOSI OPTIONS...]
#
#   usb      a bootable USB stick / SD card: ESP with signed systemd-boot and
#            UKI, erofs root and its dm-verity hash tree on the medium.
#            Write it with ./burn.sh, check it with ./diagnose.sh.
#   network  UEFI HTTP (or PXE/TFTP) netboot: the signed UKI plus the root
#            image and its hash tree as separate files, to be published with
#            ./release.sh. See NETBOOT.md.
#
# --groups LIST  package groups, comma-separated, case-insensitive (default:
#              base). base: the base system only (always included);
#              remotedesktop: XFCE desktop over VNC; docker: Docker with its
#              data disk. E.g. --groups base,RemoteDesktop,docker.
#              See lib/groups.sh and mkosi.profiles/<group>/.
#
# The network variant needs the base URL of the network releases on the
# distribution server. The build appends its own image version to it, e.g.
#   --url http://10.0.0.1/safespace/network/  ->  http://10.0.0.1/safespace/network/20261016-1830/
# so a UKI always loads the root image it was signed with. Give --url more
# than once for failover (tried in order), or put it in netboot.conf
# (NETROOT_URL=, see netboot.conf.example) and leave the option out.
#
# Package source: SNAPSHOT= and MIRROR= in repos.conf, overridden per host by
# repos.local.conf (see repos.local.conf.example). A pinned date, or latest,
# each with mkosi's default mirror or your own. Not settable on the command
# line, so every build of a checkout uses the same source; build.sh checks
# that the mirror serves core.db before the build starts.
#
# --workers N  threads for the erofs compression of the root (mkfs.erofs,
#              default 4; 0 would mean single-threaded, so N >= 1). Overrides
#              mkosi.local.conf for this run; set it there to keep it.
#
# --debug      add the "debug" profile (mkosi.profiles/debug/: ethtool,
#              dmidecode, pciutils, kexec-tools, tcpdump, ...) and append
#              "-debug" to the image version.
#
# Everything else after the variant is passed to mkosi unchanged, e.g.
#   sudo ./build.sh usb -f          force a rebuild of unchanged packages
#   sudo ./build.sh usb --groups base,remotedesktop
#   sudo ./build.sh network summary show the resolved configuration
#
# Building needs root, because the UKI is signed with the sbctl db key in
# /var/lib/sbctl, which is readable by root only. Read-only verbs (summary,
# cat-config) run as a normal user.
#
# Every build exports the public Secure Boot keys it signs with into the image
# (secureboot-export.sh), so safespace-seal works in both variants, and
# creates the expected-PCR signing key on the first build (lib/keys.sh).
set -Eeuo pipefail

HERE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
log() { printf '\e[1;32m==>\e[0m %s\n' "$*"; }
die() { printf '\e[1;31m==> ERROR:\e[0m %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,${/^#/!q;s/^# \?//;p}' "$0"; }

VARIANT=${1:-}
case $VARIANT in
	usb | network) shift ;;
	-h | --help) usage; exit 0 ;;
	'') usage >&2; exit 1 ;;
	*) usage >&2; die "unknown variant '$VARIANT' (expected usb or network)" ;;
esac

URLS=()
NETROOT=()
GROUP_LIST=base
WORKERS=""
DEBUG=0
MKOSI_ARGS=()
while (($#)); do
	case $1 in
		--url) URLS+=("${2:?--url needs a base URL}"); shift 2 ;;
		--url=*) URLS+=("${1#--url=}"); shift ;;
		--groups) GROUP_LIST=${2:?--groups needs a comma-separated list}; shift 2 ;;
		--groups=*) GROUP_LIST=${1#--groups=}; shift ;;
		--workers) WORKERS=${2:?--workers needs a thread count}; shift 2 ;;
		--workers=*) WORKERS=${1#--workers=}; shift ;;
		--debug) DEBUG=1; shift ;;
		-m* | --mirror | --mirror=* | --snapshot | --snapshot=*)
			die "$1: the package source is set in repos.conf / repos.local.conf (SNAPSHOT=, MIRROR=)" ;;
		-h | --help) usage; exit 0 ;;
		*) MKOSI_ARGS+=("$1"); shift ;;
	esac
done
[[ -z $WORKERS || $WORKERS =~ ^[1-9][0-9]*$ ]] || die "--workers needs a thread count >= 1, got '$WORKERS'"

command -v mkosi >/dev/null || die "mkosi not found (pacman -S mkosi)"

# shellcheck source=lib/groups.sh
source "$HERE/lib/groups.sh"
groups_parse "$GROUP_LIST"
mapfile -t GROUP_PROFILES < <(groups_profiles)

# shellcheck source=lib/repos.sh
source "$HERE/lib/repos.sh"
repos_load "$HERE"
mapfile -t REPO_ARGS < <(repos_mkosi_args)

# No verb in the arguments: build. Only the verbs that touch the image need root.
VERB=build
for a in ${MKOSI_ARGS[@]+"${MKOSI_ARGS[@]}"}; do
	case $a in
		build | summary | cat-config | shell | boot | vm | qemu | ssh | journalctl | clean | sysupdate | sandbox | burn | documentation | dependencies)
			VERB=$a; break ;;
	esac
done
APPEND_VERB=""
[[ " ${MKOSI_ARGS[*]-} " == *" $VERB "* ]] || APPEND_VERB=1
case $VERB in
	build | shell | boot | vm | qemu | clean | burn)
		[[ $EUID -eq 0 ]] || die "'$VERB' must run as root (the sbctl db key is root-only): sudo $0 $VARIANT ${MKOSI_ARGS[*]-}"
		[[ -f $HERE/users.conf ]] || die "users.conf missing: cp users.conf.example users.conf and add your ssh keys"
		;;
esac
if [[ $VERB == build ]]; then
	# Host tools that mkosi (without a tools tree) runs from the host.
	missing=()
	for tool in cpio curl ukify sbctl mkfs.erofs mkfs.vfat mcopy zstd systemd-repart openssl cert-to-efi-sig-list sign-efi-sig-list; do
		command -v "$tool" >/dev/null || missing+=("$tool")
	done
	[[ -x /usr/lib/systemd/systemd-measure ]] || command -v systemd-measure >/dev/null || missing+=(systemd-measure)
	((${#missing[@]} == 0)) ||
		die "missing host tools: ${missing[*]} (see README.md, Quick start: pacman -S --needed ...)"
fi

# The same version goes into the output names and, for the network variant,
# into the netroot URL, so it must be fixed here instead of letting mkosi run
# ./mkosi.version twice.
VERSION=$("$HERE/mkosi.version")
PROFILES=(--profile="$VARIANT" ${GROUP_PROFILES[@]+"${GROUP_PROFILES[@]}"})
if ((DEBUG)); then
	PROFILES+=(--profile=debug)
	VERSION+=-debug
fi
EXTRA=("${PROFILES[@]}" --image-version="$VERSION" ${REPO_ARGS[@]+"${REPO_ARGS[@]}"})
[[ -z $WORKERS ]] || EXTRA+=(--environment="SYSTEMD_REPART_MKFS_OPTIONS_EROFS=--workers=$WORKERS")

if [[ $VARIANT == network ]]; then
	if ((${#URLS[@]} == 0)); then
		# shellcheck source=/dev/null
		[[ -f $HERE/netboot.conf ]] && source "$HERE/netboot.conf"
		read -ra URLS <<<"${NETROOT_URL:-}"
	fi
	((${#URLS[@]})) || die "no netboot URL: pass --url http://SERVER/safespace/ or set NETROOT_URL in netboot.conf (see netboot.conf.example)"
	for url in "${URLS[@]}"; do
		[[ $url == http://* || $url == https://* ]] || die "netboot URL must start with http:// or https://: $url"
		host=${url#*//}; host=${host%%/*}; host=${host%%:*}
		[[ $host =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ || $host =~ ^\[ ]] ||
			log "note: $host is a host name; the initrd resolves it with the DNS servers from the DHCP lease, so that answer has to carry a resolver that knows it (an IP address needs no DNS at all)"
		NETROOT+=("${url%/}/$VERSION/")
		EXTRA+=(--kernel-command-line="safespace.netroot=${url%/}/$VERSION/")
	done
fi

log "Running variant $VARIANT$( ((DEBUG)) && echo ' + debug'), version $VERSION"
log "package groups: $(IFS=,; echo "${SAFESPACE_GROUPS[*]}")"
log "packages: $(repos_describe)"
((${#NETROOT[@]})) && log "netroot: ${NETROOT[*]}"
[[ -n $WORKERS ]] && log "erofs compression: $WORKERS threads"
if [[ $VERB == build ]]; then
	repos_check
	# shellcheck source=lib/keys.sh
	source "$HERE/lib/keys.sh"
	summary=$(mktemp)
	mkosi "${EXTRA[@]}" --json summary >"$summary" || { rm -f "$summary"; die "mkosi summary failed"; }
	keys_load "$summary"
	rm -f "$summary"
	keys_export_secureboot "$HERE"
	keys_ensure_pcr
	[[ $SNAPSHOT == latest ]] && log "note: SNAPSHOT=latest reuses the cached image as long as the configuration is unchanged; -f installs the current packages"
fi
set -x
mkosi "${EXTRA[@]}" ${MKOSI_ARGS[@]+"${MKOSI_ARGS[@]}"} ${APPEND_VERB:+build}
{ set +x; } 2>/dev/null

[[ $VERB == build ]] || exit 0
log "Outputs in mkosi.output/ for safespace-arch-${VARIANT}_$VERSION"
if [[ $VARIANT == usb ]]; then
	log "Next: sudo ./burn.sh /dev/sdX   (then sudo ./diagnose.sh /dev/sdX), or ./release.sh usb --push ..."
else
	log "Next: ./release.sh network --push safespace@<distribution server>   (see README.md, \"Releasing\")"
fi
