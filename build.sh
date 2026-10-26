#!/usr/bin/env bash
# Build safespace-arch with mkosi, and keep track of the builds on this host.
# A build is the whole stack: every combination of combinations.conf as a
# complete, dm-verity protected root of its own (one mkosi run each), and one
# signed UKI that names them all (lib/compose.sh). The same build boots from a
# USB stick / SD card (./burn.sh) and over the network (./release.sh to the
# distribution servers, NETBOOT.md); a machine boots the first combination
# unless safespace-select preselects another (an EFI variable).
#
#   sudo ./build.sh [--url BASE_URL]... [--workers N] [--users FILE]
#                   [--combinations FILE] [--output-root DIR] [MKOSI OPTIONS...]
#
#   ./build.sh list                 the builds: built at, snapshot, packages,
#                                   size, last release
#   ./build.sh show BUILD           details of a build and its package lists
#   ./build.sh diff BUILD BUILD     packages added, removed, changed
#   ./build.sh prune [--keep N] [--yes]
#                                   keep the newest N builds (default 3); the
#                                   build last released to each target always
#                                   stays
#   sudo ./build.sh purge-cache [--packages]
#                                   drop mkosi's image cache (and with
#                                   --packages the downloaded packages); the
#                                   next build installs everything anew
#
# Each build gets a directory of its own, named by its build time:
#   mkosi.output/combined_<version>/   e.g. mkosi.output/combined_20261019-0930/
# with the parts (boot.efi, systemd-boot.efi, layout.sfdisk; per combination
# root-<name>.img, root-<name>.verity, roothash-<name>, manifest-<name>.json;
# lib/compose.sh), build.json (what, when, from which package snapshot and
# commit); release.sh adds released.log. BUILD in the commands above is that
# directory name. While building, each combination's mkosi run has its own
# directory under mkosi.output/.parts-<version>/ (removed when composed).
#
# --url BASE_URL  where a network-booted machine loads its root from: the
#              distribution servers' share, e.g. http://10.0.0.1/safespace/
#              (a server only holds the newest release). More than once for
#              failover (tried in order), or NETROOT_URL= in netboot.conf
#              (netboot.conf.example). Without any, the build boots from
#              sticks only.
#
# --users FILE    the users and ssh keys to build in (default: users.conf);
# --combinations FILE  the combinations to build (default: combinations.conf);
# --output-root DIR  where the build's directory goes (default: mkosi.output).
#              All inside this checkout. For test builds (tests/vm.sh: a
#              throwaway user, its own combinations, kept apart from the real
#              builds, so list and release.sh never offer them).
#
# Package source: SNAPSHOT= and MIRROR= in repos.conf, overridden per host by
# repos.local.conf (see repos.local.conf.example). A pinned date, or latest,
# each with mkosi's default mirror or your own. Not settable on the command
# line, so every build of a checkout uses the same source; build.sh checks
# that the mirror serves core.db before the build starts.
#
# --workers N  threads for the erofs compression of the roots (mkfs.erofs;
#              0 would mean single-threaded, so N >= 1). Without it: the
#              setting in mkosi.local.conf, else all available CPUs (nproc,
#              which respects CPU affinity and limits).
#
# Before a build, the free disk space where the build lands and where mkosi
# works (/var/tmp), and the available RAM are checked: too little disk stops
# the build before it starts, little RAM only warns.
#
# MKOSI OPTIONS are passed to every combination's mkosi run, e.g.
#   sudo ./build.sh -f              force a rebuild of unchanged packages
#   sudo ./build.sh --kernel-command-line console=ttyS0,115200
# mkosi verbs are not: build.sh only builds. A combination's configuration:
#   mkosi --profile=docker summary  (the groups of the combination as profiles)
#
# Building needs root, because the UKI is signed with the sbctl db key in
# /var/lib/sbctl, which is readable by root only.
#
# Every build builds aSSH (the submodule assh/, the machine's host key in the
# TPM: lib/assh.sh) on this host with its Go into every root; the module cache
# is mkosi.cache/go.
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

[[ ${1:-} == -h || ${1:-} == --help ]] && { usage; exit 0; }

URLS=()
NETROOT=()
USERS_FILE=users.conf
COMBOS_FILE=combinations.conf
OUTPUT_ROOT=mkosi.output
WORKERS=""
MKOSI_ARGS=()
while (($#)); do
	case $1 in
		--url) URLS+=("${2:?--url needs a base URL}"); shift 2 ;;
		--url=*) URLS+=("${1#--url=}"); shift ;;
		--users) USERS_FILE=${2:?--users needs a file}; shift 2 ;;
		--combinations) COMBOS_FILE=${2:?--combinations needs a file}; shift 2 ;;
		--output-root) OUTPUT_ROOT=${2:?--output-root needs a directory}; shift 2 ;;
		--workers) WORKERS=${2:?--workers needs a thread count}; shift 2 ;;
		--workers=*) WORKERS=${1#--workers=}; shift ;;
		--groups | --groups=* | --debug | --combined | --version)
			die "$1: there is none; combinations.conf decides what is built (a debug combination is one of them)" ;;
		-m* | --mirror | --mirror=* | --snapshot | --snapshot=*)
			die "$1: the package source is set in repos.conf / repos.local.conf (SNAPSHOT=, MIRROR=)" ;;
		build) shift ;;
		summary | cat-config | shell | boot | vm | qemu | ssh | journalctl | clean | sysupdate | sandbox | burn | documentation | dependencies | genkey | serve | bump | init | completion)
			die "'$1': build.sh only builds (a combination's configuration: mkosi --profile=GROUP $1)" ;;
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
[[ $EUID -eq 0 ]] || die "building must run as root (the sbctl db key is root-only): sudo $0"

# --users / --output-root: relative paths inside the checkout (mkosi sees the
# checkout as $SRCDIR in its scripts).
inside() { # PATH: a plain relative path below the checkout
	[[ $1 =~ ^[A-Za-z0-9._/-]+$ && $1 != /* && /$1/ != */../* ]]
}
USERS_FILE=${USERS_FILE#./} OUTPUT_ROOT=${OUTPUT_ROOT#./} COMBOS_FILE=${COMBOS_FILE#./}
inside "$USERS_FILE" || die "--users: a relative path inside the checkout, got '$USERS_FILE'"
inside "$COMBOS_FILE" || die "--combinations: a relative path inside the checkout, got '$COMBOS_FILE'"
inside "$OUTPUT_ROOT" || die "--output-root: a relative path inside the checkout, got '$OUTPUT_ROOT'"
[[ -f $HERE/$USERS_FILE ]] || die "$USERS_FILE missing: cp users.conf.example users.conf and add your ssh keys"
BUILDS_ROOT=$HERE/${OUTPUT_ROOT%/}

# shellcheck source=lib/groups.sh
source "$HERE/lib/groups.sh"
# shellcheck source=lib/verify.sh
source "$HERE/lib/verify.sh"
# shellcheck source=lib/compose.sh
source "$HERE/lib/compose.sh"
combos_load "$HERE/$COMBOS_FILE"
# shellcheck source=lib/repos.sh
source "$HERE/lib/repos.sh"
repos_load "$HERE"
mapfile -t REPO_ARGS < <(repos_mkosi_args)

# Host tools that mkosi (without a tools tree) runs from the host, and what
# composing and checking the build needs.
missing=()
for tool in cpio curl ukify sbctl sbverify objcopy objdump mkfs.erofs mkfs.vfat mcopy sfdisk zstd systemd-repart openssl cert-to-efi-sig-list sign-efi-sig-list go; do
	command -v "$tool" >/dev/null || missing+=("$tool")
done
[[ -x /usr/lib/systemd/systemd-measure ]] || command -v systemd-measure >/dev/null || missing+=(systemd-measure)
((${#missing[@]} == 0)) ||
	die "missing host tools: ${missing[*]} (see README.md, Quick start: pacman -S --needed ...)"

# Resources. Each combination's mkosi run needs its disk image (~3 GiB) next
# to the parts of the combinations built before it where the build lands, and
# mkosi's work tree in /var/tmp (the whole installed system); mkfs.erofs with
# many threads wants some RAM.
free_gib() { df -BG --output=avail "$1" 2>/dev/null | tail -1 | tr -dc 0-9; }
mkdir -p "$BUILDS_ROOT"
out_free=$(free_gib "$BUILDS_ROOT") tmp_free=$(free_gib /var/tmp)
need_out=$((8 + 3 * ${#COMBO_NAMES[@]}))
[[ -z $out_free ]] || ((out_free >= need_out)) ||
	die "only ${out_free} GiB free for the build in ${BUILDS_ROOT#"$HERE"/}/ (needs ~$need_out GiB for ${#COMBO_NAMES[@]} combinations; ./build.sh prune, sudo ./build.sh purge-cache)"
[[ -z $tmp_free ]] || ((tmp_free >= 8)) ||
	die "only ${tmp_free} GiB free in /var/tmp, where mkosi builds the image (needs ~8 GiB)"
mem=$(awk '/^MemAvailable:/ { print int($2 / 1048576) }' /proc/meminfo)
((mem >= 2)) || log "WARNING: only ${mem} GiB RAM available; the build may be slow or fail (fewer --workers help)"
log "resources: $(nproc) CPUs, ${mem} GiB RAM available, ${out_free:-?} GiB free for builds, ${tmp_free:-?} GiB in /var/tmp"

# The version goes into the output names and the release; fixed here so that
# mkosi does not run ./mkosi.version once per combination. A second build in
# the same minute gets the seconds too.
VERSION=$("$HERE/mkosi.version")
[[ -e $BUILDS_ROOT/combined_$VERSION ]] && VERSION=$(date +%Y%m%d-%H%M%S)
[[ $VERSION =~ ^[0-9]{8}-[0-9]{4,6}$ ]] || die "invalid version '$VERSION'"
BUILD=combined_$VERSION
OUTDIR=$(builds_dir "$BUILD")
PARTS=$BUILDS_ROOT/.parts-$VERSION
# What every combination's mkosi run gets.
EXTRA=(--image-version="$VERSION" ${REPO_ARGS[@]+"${REPO_ARGS[@]}"} --environment="SAFESPACE_USERS_CONF=$USERS_FILE")
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

log "build $BUILD: ${COMBO_NAMES[*]} (default ${COMBO_NAMES[0]})"
log "packages: $(repos_describe)"
if ((${#NETROOT[@]})); then log "netroot: ${NETROOT[*]}"; else log "no NETROOT_URL (netboot.conf / --url): this build boots from sticks only"; fi
if [[ -n $WORKERS ]]; then log "erofs compression: $WORKERS threads ($WORKERS_FROM)"; else log "erofs compression: threads from mkosi.local.conf"; fi
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
DB_EXPORT=$HERE/mkosi.extra/usr/share/safespace/secureboot
keys_export "$DB_EXPORT"
# shellcheck source=lib/assh.sh
source "$HERE/lib/assh.sh"
assh_build "$HERE/mkosi.extra/usr/bin/assh"
# Keep the project owned by its user, not by root.
chown -R --reference="$HERE" "$HERE/mkosi.extra/usr/share/safespace" "$HERE/mkosi.extra/usr/bin/assh"
keys_ensure_pcr
[[ $SNAPSHOT == latest ]] && log "note: SNAPSHOT=latest reuses the cached image as long as the configuration is unchanged; -f installs the current packages"

# The parts of an earlier failed run (kept for a look at them) go now.
find "$BUILDS_ROOT" -mindepth 1 -maxdepth 1 -type d -name '.parts-*' -exec rm -rf -- {} + 2>/dev/null || true
STARTED=$(date -Is)

# One combination: its own complete mkosi run with its groups as profiles,
# finalized into its parts (lib/builds.sh).
build_combination() { # NAME GROUPS DIR
	local name=$1 groups=$2 dir=$3 profiles
	groups_parse "$groups"
	mapfile -t profiles < <(groups_profiles)
	log "--- combination $name (groups $groups)"
	mkdir -p "$dir"
	# (Called in a condition, where set -e does not apply: every step returns.)
	(set -x; mkosi ${profiles[@]+"${profiles[@]}"} "${EXTRA[@]}" --environment="SAFESPACE_COMBINATION=$name" --output-directory="$dir" ${MKOSI_ARGS[@]+"${MKOSI_ARGS[@]}"} build) || return 1
	(builds_finalize "$dir" "$VERSION")
}
dirs=()
for i in "${!COMBO_NAMES[@]}"; do
	build_combination "${COMBO_NAMES[i]}" "${COMBO_GROUPS[i]}" "$PARTS/${COMBO_NAMES[i]}" ||
		die "the build of ${COMBO_NAMES[i]} failed (parts in ${PARTS#"$HERE"/})"
	dirs+=("$PARTS/${COMBO_NAMES[i]}")
done

log "composing $BUILD"
compose_build "$OUTDIR" "${dirs[@]}"
compose_check "$OUTDIR" "$DB_EXPORT/db.pem"

# What was built, from what (build.json marks the build as complete).
combos=""
for i in "${!COMBO_NAMES[@]}"; do combos+="${COMBO_NAMES[i]}:${COMBO_GROUPS[i]//,/+},"; done
git=(git -c safe.directory="$HERE" -C "$HERE")
builds_write_info "$OUTDIR" build="$BUILD" version="$VERSION" combinations="${combos%,}" \
	started="$STARTED" finished="$(date -Is)" snapshot="$SNAPSHOT" mirror="${MIRROR:-default}" \
	commit="$("${git[@]}" rev-parse --short HEAD 2>/dev/null || echo none)" \
	uncommitted_changes="$([[ -z $("${git[@]}" status --porcelain 2>/dev/null) ]] && echo no || echo yes)" \
	signer="$(keys_fingerprint "$KEYS_SB_CERT")" netroot="$(IFS=,; echo "${NETROOT[*]-}")" \
	builder="$(uname -n)" users="$USERS_FILE"
rm -rf -- "${PARTS:?}"
# The build belongs to whoever ran sudo, so list, release.sh and prune work
# without root. (Changing a file there gains nothing: release.sh and the
# servers check signature and root hashes.)
if [[ -n ${SUDO_UID:-} ]]; then
	chown "$SUDO_UID:$SUDO_GID" "$BUILDS_ROOT"
	chown -R "$SUDO_UID:$SUDO_GID" "$OUTDIR"
fi
log "Build $BUILD in ${OUTDIR#"$HERE"/} (${COMBO_NAMES[*]})"
log "Next: ./release.sh --build $BUILD (to the distribution servers), sudo ./burn.sh $BUILD /dev/sdX (a stick)"
