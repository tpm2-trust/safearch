#!/usr/bin/env bash
# Build safespace-arch with mkosi, and keep track of the builds on this host.
# One build serves both boot paths: the same signed UKI and root boot from a
# USB stick / SD card (./burn.sh) and over the network (./release.sh to the
# distribution servers, NETBOOT.md).
#
#   sudo ./build.sh [--groups LIST] [--url BASE_URL]... [--workers N] [--debug]
#                   [--users FILE] [--output-root DIR] [MKOSI OPTIONS...]
#
#   ./build.sh list                 the builds: groups, built at, snapshot,
#                                   packages, size, last release
#   ./build.sh show BUILD           details of a build and its package list
#   ./build.sh diff BUILD BUILD     packages added, removed, changed
#   ./build.sh prune [--keep N] [--yes]
#                                   keep the newest N builds (default 3) per
#                                   group set; the build last released to each
#                                   target always stays
#   sudo ./build.sh purge-cache [--packages]
#                                   drop mkosi's image cache (and with
#                                   --packages the downloaded packages); the
#                                   next build installs everything anew
#
# Each build gets a directory of its own, named by its group set and build
# time, so the builds of one group set sort together:
#   mkosi.output/<groups>_<version>/   e.g. mkosi.output/base-remotedesktop_20261019-0930/
# with the parts (boot.efi, root.img, root.verity, roothash, systemd-boot.efi,
# layout.sfdisk, manifest.json; lib/builds.sh), build.json (what, when, from
# which package snapshot and commit); release.sh adds released.log. BUILD in
# the commands above is that directory name.
#
# --groups LIST  package groups, comma-separated, case-insensitive (default:
#              base). base: the base system only (always included);
#              remotedesktop: XFCE desktop over VNC; docker: Docker with its
#              data disk. E.g. --groups base,RemoteDesktop,docker.
#              See lib/groups.sh and mkosi.profiles/<group>/.
#
# --url BASE_URL  where a network-booted machine loads root.img and
#              root.verity from: the distribution servers' share, e.g.
#              http://10.0.0.1/safespace/ (a server only holds the newest
#              release). More than once for failover (tried in order), or
#              NETROOT_URL= in netboot.conf (netboot.conf.example). Without
#              any, the build boots from sticks only.
#
# --users FILE    the users and ssh keys to build in (default: users.conf);
# --output-root DIR  where the build's directory goes (default: mkosi.output).
#              Both inside this checkout. For test builds (tests/vm.sh: a
#              throwaway user, kept apart from the real builds, so list and
#              release.sh never offer them).
#
# Package source: SNAPSHOT= and MIRROR= in repos.conf, overridden per host by
# repos.local.conf (see repos.local.conf.example). A pinned date, or latest,
# each with mkosi's default mirror or your own. Not settable on the command
# line, so every build of a checkout uses the same source; build.sh checks
# that the mirror serves core.db before the build starts.
#
# --workers N  threads for the erofs compression of the root (mkfs.erofs;
#              0 would mean single-threaded, so N >= 1). Without it: the
#              setting in mkosi.local.conf, else all available CPUs (nproc,
#              which respects CPU affinity and limits).
#
# Before a build, the free disk space where the build lands and where mkosi
# works (/var/tmp), and the available RAM are checked: too little disk stops
# the build before it starts, little RAM only warns.
#
# --debug      add the "debug" profile (mkosi.profiles/debug/: ethtool,
#              dmidecode, pciutils, kexec-tools, tcpdump, ...) and append
#              "-debug" to the image version.
#
# Everything else is passed to mkosi unchanged, e.g.
#   sudo ./build.sh -f              force a rebuild of unchanged packages
#   sudo ./build.sh --groups base,remotedesktop
#   ./build.sh summary              show the resolved configuration
#
# Building needs root, because the UKI is signed with the sbctl db key in
# /var/lib/sbctl, which is readable by root only. Read-only verbs (summary,
# cat-config) run as a normal user.
#
# Every build exports the public Secure Boot keys it signs with into the image
# (mkosi.extra/usr/share/safespace/secureboot/), so safespace-seal works, and
# creates the expected-PCR signing key on the first build (lib/keys.sh). The
# keys: the host's sbctl (/var/lib/sbctl), or a dedicated sbctl key set,
# SAFESPACE_SBCTL_CONFIG= in mkosi.local.conf (README.md, "Secure Boot keys").
set -Eeuo pipefail

HERE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
log() { printf '\e[1;32m==>\e[0m %s\n' "$*"; }
die() { printf '\e[1;31m==> ERROR:\e[0m %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,${/^#/!q;s/^# \?//;p}' "$0"; }
# shellcheck source=lib/builds.sh
source "$HERE/lib/builds.sh"

# --- managing the builds (no mkosi run) ----------------------------------------
case ${1:-} in
	list)
		builds_list
		exit 0 ;;
	show)
		builds_show "$(builds_find "${2:?show needs a build (./build.sh list)}")"
		exit 0 ;;
	diff)
		a=$(builds_find "${2:?diff needs two builds}") b=$(builds_find "${3:?diff needs two builds}")
		builds_diff "$a" "$b"
		exit 0 ;;
	prune)
		shift
		keep=3 yes=0
		while (($#)); do
			case $1 in
				--keep) keep=${2:?--keep needs a number}; shift 2 ;;
				--yes) yes=1; shift ;;
				*) die "prune: unknown option $1" ;;
			esac
		done
		[[ $keep =~ ^[1-9][0-9]*$ ]] || die "--keep needs a number >= 1"
		builds_prune "$keep" "$yes"
		exit 0 ;;
	purge-cache)
		[[ $EUID -eq 0 ]] || die "purge-cache must run as root (the caches belong to root): sudo $0 purge-cache"
		[[ -z ${2:-} || $2 == --packages ]] || die "purge-cache: only --packages"
		log "removing mkosi's image cache (mkosi.cache/)"
		find "$HERE/mkosi.cache" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2>/dev/null || true
		if [[ ${2:-} == --packages ]]; then
			log "removing the downloaded packages (mkosi.pkgcache/)"
			find "$HERE/mkosi.pkgcache" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2>/dev/null || true
		fi
		exit 0 ;;
esac

case ${1:-} in
	usb | network) die "there are no variants any more: one build serves sticks and the network (sudo $0 [--groups ...])" ;;
	-h | --help) usage; exit 0 ;;
esac

URLS=()
NETROOT=()
GROUP_LIST=base
USERS_FILE=users.conf
OUTPUT_ROOT=mkosi.output
WORKERS=""
DEBUG=0
MKOSI_ARGS=()
while (($#)); do
	case $1 in
		--url) URLS+=("${2:?--url needs a base URL}"); shift 2 ;;
		--url=*) URLS+=("${1#--url=}"); shift ;;
		--groups) GROUP_LIST=${2:?--groups needs a comma-separated list}; shift 2 ;;
		--groups=*) GROUP_LIST=${1#--groups=}; shift ;;
		--users) USERS_FILE=${2:?--users needs a file}; shift 2 ;;
		--output-root) OUTPUT_ROOT=${2:?--output-root needs a directory}; shift 2 ;;
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
# No --workers and nothing in mkosi.local.conf: all available CPUs.
WORKERS_FROM="--workers"
if [[ -z $WORKERS ]]; then
	if grep -qs '^[^#]*SYSTEMD_REPART_MKFS_OPTIONS_EROFS=' "$HERE/mkosi.local.conf"; then
		WORKERS_FROM=mkosi.local.conf
	else
		WORKERS=$(nproc 2>/dev/null || echo 1)
		WORKERS_FROM="all available CPUs"
	fi
fi

command -v mkosi >/dev/null || die "mkosi not found (pacman -S mkosi)"

# --users / --output-root: relative paths inside the checkout (mkosi sees the
# checkout as $SRCDIR in its scripts).
inside() { # PATH: a plain relative path below the checkout
	[[ $1 =~ ^[A-Za-z0-9._/-]+$ && $1 != /* && /$1/ != */../* ]]
}
USERS_FILE=${USERS_FILE#./} OUTPUT_ROOT=${OUTPUT_ROOT#./}
inside "$USERS_FILE" || die "--users: a relative path inside the checkout, got '$USERS_FILE'"
inside "$OUTPUT_ROOT" || die "--output-root: a relative path inside the checkout, got '$OUTPUT_ROOT'"
BUILDS_ROOT=$HERE/${OUTPUT_ROOT%/}

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
		[[ $EUID -eq 0 ]] || die "'$VERB' must run as root (the sbctl db key is root-only): sudo $0 ${MKOSI_ARGS[*]-}"
		[[ -f $HERE/$USERS_FILE ]] || die "$USERS_FILE missing: cp users.conf.example users.conf and add your ssh keys"
		;;
esac
if [[ $VERB == build ]]; then
	# Host tools that mkosi (without a tools tree) runs from the host.
	missing=()
	for tool in cpio curl ukify sbctl mkfs.erofs mkfs.vfat mcopy sfdisk zstd systemd-repart openssl cert-to-efi-sig-list sign-efi-sig-list; do
		command -v "$tool" >/dev/null || missing+=("$tool")
	done
	[[ -x /usr/lib/systemd/systemd-measure ]] || command -v systemd-measure >/dev/null || missing+=(systemd-measure)
	((${#missing[@]} == 0)) ||
		die "missing host tools: ${missing[*]} (see README.md, Quick start: pacman -S --needed ...)"

	# Resources. A build needs the disk image (~2.5 GiB) next to its parts
	# (~2.2 GiB) where it lands, and mkosi's work tree in /var/tmp (the whole
	# installed system); mkfs.erofs with many threads wants some RAM.
	free_gib() { df -BG --output=avail "$1" 2>/dev/null | tail -1 | tr -dc 0-9; }
	mkdir -p "$BUILDS_ROOT"
	out_free=$(free_gib "$BUILDS_ROOT") tmp_free=$(free_gib /var/tmp)
	[[ -z $out_free ]] || ((out_free >= 8)) ||
		die "only ${out_free} GiB free for the build in ${BUILDS_ROOT#"$HERE"/}/ (needs ~8 GiB; ./build.sh prune, sudo ./build.sh purge-cache)"
	[[ -z $tmp_free ]] || ((tmp_free >= 8)) ||
		die "only ${tmp_free} GiB free in /var/tmp, where mkosi builds the image (needs ~8 GiB)"
	mem=$(awk '/^MemAvailable:/ { print int($2 / 1048576) }' /proc/meminfo)
	((mem >= 2)) || log "WARNING: only ${mem} GiB RAM available; the build may be slow or fail (fewer --workers help)"
	log "resources: $(nproc) CPUs, ${mem} GiB RAM available, ${out_free:-?} GiB free for builds, ${tmp_free:-?} GiB in /var/tmp"
fi

# The version goes into the output names and the release; fixed here so that
# mkosi does not run ./mkosi.version twice. A second build of the same group
# set in the same minute gets the seconds too.
VERSION=$("$HERE/mkosi.version")
GROUPS_CSV=$(IFS=,; echo "${SAFESPACE_GROUPS[*]}")
SUFFIX=""
((DEBUG)) && SUFFIX=-debug
[[ -e $(builds_dir "$(builds_id "$GROUPS_CSV" "$VERSION$SUFFIX")") ]] && VERSION=$(date +%Y%m%d-%H%M%S)
VERSION+=$SUFFIX
PROFILES=(${GROUP_PROFILES[@]+"${GROUP_PROFILES[@]}"})
((DEBUG)) && PROFILES+=(--profile=debug)
BUILD=$(builds_id "$GROUPS_CSV" "$VERSION")
OUTDIR=$(builds_dir "$BUILD")
EXTRA=(${PROFILES[@]+"${PROFILES[@]}"} --image-version="$VERSION" ${REPO_ARGS[@]+"${REPO_ARGS[@]}"}
	--environment="SAFESPACE_USERS_CONF=$USERS_FILE")
[[ $VERB == build ]] && EXTRA+=(--output-directory="$OUTDIR")
[[ -z $WORKERS ]] || EXTRA+=(--environment="SYSTEMD_REPART_MKFS_OPTIONS_EROFS=--workers=$WORKERS")

if ((${#URLS[@]} == 0)); then
	# shellcheck source=/dev/null
	[[ -f $HERE/netboot.conf ]] && source "$HERE/netboot.conf"
	read -ra URLS <<<"${NETROOT_URL:-}"
fi
for url in ${URLS[@]+"${URLS[@]}"}; do
	[[ $url == http://* || $url == https://* ]] || die "netboot URL must start with http:// or https://: $url"
	host=${url#*//}; host=${host%%/*}; host=${host%%:*}
	[[ $host =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ || $host =~ ^\[ ]] ||
		log "note: $host is a host name; the initrd resolves it with the DNS servers from the DHCP lease, so that answer has to carry a resolver that knows it (an IP address needs no DNS at all)"
	NETROOT+=("${url%/}/")
	EXTRA+=(--kernel-command-line="safespace.netroot=${url%/}/")
done

log "Running version $VERSION$( ((DEBUG)) && echo ' (debug)')"
log "package groups: $GROUPS_CSV"
[[ $VERB == build ]] && log "build: $BUILD"
log "packages: $(repos_describe)"
if ((${#NETROOT[@]})); then log "netroot: ${NETROOT[*]}"; else log "no NETROOT_URL (netboot.conf / --url): this build boots from sticks only"; fi
if [[ -n $WORKERS ]]; then log "erofs compression: $WORKERS threads ($WORKERS_FROM)"; else log "erofs compression: threads from mkosi.local.conf"; fi
if [[ $VERB == build ]]; then
	repos_check
	# shellcheck source=lib/keys.sh
	source "$HERE/lib/keys.sh"
	summary=$(mktemp)
	mkosi "${EXTRA[@]}" --json summary >"$summary" || { rm -f "$summary"; die "mkosi summary failed"; }
	keys_load "$summary"
	rm -f "$summary"
	mapfile -t key_args < <(keys_mkosi_args)
	EXTRA+=(${key_args[@]+"${key_args[@]}"})
	log "Secure Boot keys: $KEYS_SB_DIR$( ((KEYS_DEDICATED)) && echo ' (dedicated key set)')"
	keys_export "$HERE/mkosi.extra/usr/share/safespace/secureboot"
	# Keep the project owned by its user, not by root.
	chown -R --reference="$HERE" "$HERE/mkosi.extra/usr/share/safespace"
	keys_ensure_pcr
	[[ $SNAPSHOT == latest ]] && log "note: SNAPSHOT=latest reuses the cached image as long as the configuration is unchanged; -f installs the current packages"
	mkdir -p "$OUTDIR"
	STARTED=$(date -Is)
fi
set -x
mkosi "${EXTRA[@]}" ${MKOSI_ARGS[@]+"${MKOSI_ARGS[@]}"} ${APPEND_VERB:+build}
{ set +x; } 2>/dev/null

[[ $VERB == build ]] || exit 0

# Keep the parts, under short names; the whole disk image goes (lib/builds.sh).
builds_finalize "$OUTDIR" "$VERSION"

# What was built, from what (build.json marks the build as complete).
git=(git -c safe.directory="$HERE" -C "$HERE")
commit=$("${git[@]}" rev-parse --short HEAD 2>/dev/null || echo none)
dirty=no
[[ -z $("${git[@]}" status --porcelain 2>/dev/null) ]] || dirty=yes
builds_write_info "$OUTDIR" build="$BUILD" version="$VERSION" groups="$GROUPS_CSV" \
	debug="$( ((DEBUG)) && echo yes || echo no)" started="$STARTED" finished="$(date -Is)" \
	snapshot="$SNAPSHOT" mirror="${MIRROR:-default}" commit="$commit" uncommitted_changes="$dirty" \
	signer="$(keys_fingerprint "$KEYS_SB_CERT")" netroot="$(IFS=,; echo "${NETROOT[*]-}")" \
	builder="$(uname -n)" users="$USERS_FILE"
# The build belongs to whoever ran sudo, so list, release.sh and prune work
# without root. (Changing a file there gains nothing: release.sh and the
# servers check signature and root hash.)
if [[ -n ${SUDO_UID:-} ]]; then
	chown "$SUDO_UID:$SUDO_GID" "$BUILDS_ROOT"
	chown -R "$SUDO_UID:$SUDO_GID" "$OUTDIR"
fi
log "Build $BUILD in ${OUTDIR#"$HERE"/}"
log "Next: ./release.sh --build $BUILD (to the distribution servers), sudo ./burn.sh $BUILD /dev/sdX (a stick)"
