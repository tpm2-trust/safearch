#!/usr/bin/env bash
# Build safespace-arch with mkosi, and keep track of the builds on this host.
# A build is the whole stack: every combination of safespace.conf as a
# complete, dm-verity protected root of its own (one mkosi run each), and one
# signed UKI that names them all (lib/compose.sh). The same build boots from a
# USB stick / SD card (./burn.sh) and over the network (./release.sh to the
# distribution servers, NETBOOT.md); a machine boots the first combination
# unless safespace select preselects another (an EFI variable).
#
#   sudo ./build.sh [--config FILE] [--url BASE_URL]... [--workers N]
#                   [--output-root DIR] [MKOSI OPTIONS...]
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
# directory under mkosi.output/.parts-<version>/ (removed when composed). The
# first combination is built first, alone: its initrd is every combination's
# (the composed UKI carries it). The others then run side by side - as many as
# /var/tmp has room for (~8 GiB each) - each with its log in .parts-<version>/,
# printed when it ends; a combination with no cached image yet (or -f) runs on
# its own, as it installs packages into the shared package cache.
#
# What is built, from what, for whom: safespace.conf (every key, its default),
# safespace.local.conf (this host's choices, gitignored), lib/conf.sh. The
# combinations, the users file, the package source (build.sh checks that the
# mirror serves core.db before the build starts), the netroot URLs, the Secure
# Boot keys, and the machine identity's policy - checked (lib/settings.sh) and
# written into the image as assh.conf and the scripts' settings.
#
# --config FILE   one more layer of safespace.conf keys on top of both (tests/vm.sh:
#              its throwaway user, its combinations).
# --url BASE_URL  where a network-booted machine loads its root from, instead of
#              NETROOT_URL: the distribution servers' share, e.g.
#              http://10.0.0.1/safespace/ (a server only holds the newest
#              release). More than once for failover (tried in order).
# --output-root DIR  where the build's directory goes (default: mkosi.output),
#              inside this checkout. For test builds (tests/vm.sh: kept apart
#              from the real builds, so list and release.sh never offer them).
# --workers N  threads for the erofs compression of the roots (mkfs.erofs;
#              0 would mean single-threaded, so N >= 1), instead of
#              EROFS_WORKERS; without either, all available CPUs (nproc,
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
# (mkosi.extra/usr/share/safespace/secureboot/), so safespace seal works, and
# creates the expected-PCR signing key on the first build (lib/keys.sh). The
# keys: the host's sbctl (/var/lib/sbctl), or a dedicated sbctl key set,
# SBCTL_CONFIG= in safespace.local.conf (README.md, "Secure Boot keys").
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
CONFIG=""
OUTPUT_ROOT=mkosi.output
WORKERS=""
MKOSI_ARGS=()
while (($#)); do
	case $1 in
		--url) URLS+=("${2:?--url needs a base URL}"); shift 2 ;;
		--url=*) URLS+=("${1#--url=}"); shift ;;
		--config) CONFIG=$(readlink -f "${2:?--config needs a file}"); shift 2 ;;
		--users | --combinations) die "$1: USERS= / COMBINATIONS= in safespace.conf (--config FILE for one more layer)" ;;
		--output-root) OUTPUT_ROOT=${2:?--output-root needs a directory}; shift 2 ;;
		--workers) WORKERS=${2:?--workers needs a thread count}; shift 2 ;;
		--workers=*) WORKERS=${1#--workers=}; shift ;;
		--groups | --groups=* | --debug | --combined | --version)
			die "$1: there is none; COMBINATIONS in safespace.conf decides what is built (a debug combination is one of them)" ;;
		-m* | --mirror | --mirror=* | --snapshot | --snapshot=*)
			die "$1: the package source is set in safespace.conf (SNAPSHOT=, MIRROR=)" ;;
		build) shift ;;
		summary | cat-config | shell | boot | vm | qemu | ssh | journalctl | clean | sysupdate | sandbox | burn | documentation | dependencies | genkey | serve | bump | init | completion)
			die "'$1': build.sh only builds (a combination's configuration: mkosi --profile=GROUP $1)" ;;
		-h | --help) usage; exit 0 ;;
		*) MKOSI_ARGS+=("$1"); shift ;;
	esac
done
# shellcheck source=lib/conf.sh
source "$HERE/lib/conf.sh"
conf_load "$HERE" "$CONFIG"
# --workers, else EROFS_WORKERS, else all available CPUs.
WORKERS_FROM="--workers"
if [[ -z $WORKERS && -n $EROFS_WORKERS ]]; then
	WORKERS=$EROFS_WORKERS WORKERS_FROM=EROFS_WORKERS
elif [[ -z $WORKERS ]]; then
	WORKERS=$(nproc 2>/dev/null || echo 1) WORKERS_FROM="all available CPUs"
fi
[[ $WORKERS =~ ^[1-9][0-9]*$ ]] || die "$WORKERS_FROM needs a thread count >= 1, got '$WORKERS'"

command -v mkosi >/dev/null || die "mkosi not found (pacman -S mkosi)"
[[ $EUID -eq 0 ]] || die "building must run as root (the sbctl db key is root-only): sudo $0"

# USERS / --output-root: relative paths inside the checkout (mkosi sees the
# checkout as $SRCDIR in its scripts).
inside() { # PATH: a plain relative path below the checkout
	[[ $1 =~ ^[A-Za-z0-9._/-]+$ && $1 != /* && /$1/ != */../* ]]
}
USERS_FILE=${USERS#./} OUTPUT_ROOT=${OUTPUT_ROOT#./}
inside "$USERS_FILE" || die "USERS: a relative path inside the checkout, got '$USERS_FILE'"
inside "$OUTPUT_ROOT" || die "--output-root: a relative path inside the checkout, got '$OUTPUT_ROOT'"
[[ -f $HERE/$USERS_FILE ]] || die "$USERS_FILE missing: cp users.conf.example users.conf and add your ssh keys"
BUILDS_ROOT=$HERE/${OUTPUT_ROOT%/}

# shellcheck source=lib/groups.sh
source "$HERE/lib/groups.sh"
# shellcheck source=lib/verify.sh
source "$HERE/lib/verify.sh"
# shellcheck source=lib/compose.sh
source "$HERE/lib/compose.sh"
combos_load "$COMBINATIONS"
# shellcheck source=lib/repos.sh
source "$HERE/lib/repos.sh"
repos_validate
# shellcheck source=lib/settings.sh
source "$HERE/lib/settings.sh"
settings_check
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
EXTRA=(--image-version="$VERSION" ${REPO_ARGS[@]+"${REPO_ARGS[@]}"} --environment="SAFESPACE_USERS_CONF=$USERS_FILE"
	--environment="SYSTEMD_REPART_MKFS_OPTIONS_EROFS=--workers=$WORKERS")

((${#URLS[@]})) || read -ra URLS <<<"$NETROOT_URL"
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
if ((${#NETROOT[@]})); then log "netroot: ${NETROOT[*]}"; else log "no NETROOT_URL (safespace.conf / --url): this build boots from sticks only"; fi
log "erofs compression: $WORKERS threads ($WORKERS_FROM)"
log "identity: $(settings_policy)"
last=$(builds_newest)
if [[ -n $last ]]; then
	last_policy=$(builds_info "$(builds_dir "$last")" policy 2>/dev/null || true)
	[[ -z $last_policy || $last_policy == "$(settings_policy)" ]] ||
		log "note: another identity policy than $last's ($last_policy): it applies to identities made after it; a machine's existing identity keeps its own (a new one: safespace identity clear, reboot)"
fi
repos_check
# shellcheck source=lib/keys.sh
source "$HERE/lib/keys.sh"
summary=$(mktemp)
mkosi "${EXTRA[@]}" --json summary >"$summary" || { rm -f "$summary"; die "mkosi summary failed"; }
keys_load "$summary" "$SBCTL_CONFIG"
rm -f "$summary"
mapfile -t key_args < <(keys_mkosi_args)
EXTRA+=(${key_args[@]+"${key_args[@]}"})
log "Secure Boot keys: $KEYS_SB_DIR$( ((KEYS_DEDICATED)) && echo ' (dedicated key set)')"
DB_EXPORT=$HERE/mkosi.extra/usr/share/safespace/secureboot
keys_export "$DB_EXPORT"
# shellcheck source=lib/assh.sh
source "$HERE/lib/assh.sh"
assh_build "$HERE/mkosi.extra/usr/bin/assh"
# The identity's policy and the scripts' constants (lib/settings.sh): into the
# root and the initrd (which makes the identity: mkosi.initrd.conf/.../identity),
# aSSH there too, the same files as the root's. aSSH checks its settings.
for t in "$HERE/mkosi.extra" "$HERE/mkosi.initrd.conf/mkosi.extra"; do settings_write "$t"; done
assh_check_conf "$HERE/mkosi.extra/usr/bin/assh" "$HERE/mkosi.extra/etc/assh/assh.conf"
install -D -m 0755 "$HERE/mkosi.extra/usr/bin/assh" "$HERE/mkosi.initrd.conf/mkosi.extra/usr/bin/assh"
# Keep the project owned by its user, not by root.
chown -R --reference="$HERE" "$HERE/mkosi.extra/usr/share/safespace" "$HERE/mkosi.extra/usr/bin/assh" \
	"$HERE/mkosi.extra/etc/assh" "$HERE/mkosi.extra/usr/local/lib/safespace/settings" \
	"$HERE/mkosi.initrd.conf/mkosi.extra/usr/bin" "$HERE/mkosi.initrd.conf/mkosi.extra/etc/assh" \
	"$HERE/mkosi.initrd.conf/mkosi.extra/usr/local/lib/safespace/settings"
keys_ensure_pcr
[[ $SNAPSHOT == latest ]] && log "note: SNAPSHOT=latest reuses the cached image as long as the configuration is unchanged; -f installs the current packages"

# The parts of an earlier failed run (kept for a look at them) go now.
find "$BUILDS_ROOT" -mindepth 1 -maxdepth 1 -type d -name '.parts-*' -exec rm -rf -- {} + 2>/dev/null || true
STARTED=$(date -Is)

# One combination: its own complete mkosi run with its groups as profiles,
# finalized into its parts (lib/builds.sh). INITRD: the first combination's
# initrd, given to the others instead of building the same one again.
build_combination() { # NAME GROUPS DIR [INITRD]
	local name=$1 groups=$2 dir=$3 initrd=${4:-} profiles
	groups_parse "$groups"
	mapfile -t profiles < <(groups_profiles)
	log "--- combination $name (groups $groups)"
	mkdir -p "$dir"
	# Its own cache key: each combination keeps its installed image (Incremental=)
	# and finds it unchanged at the next build. With one key for all, every run
	# found the previous combination's image, re-synced the package metadata and
	# dropped every cache: each build installed every package three times.
	# (Called in a condition, where set -e does not apply: every step returns.)
	(set -x; mkosi ${profiles[@]+"${profiles[@]}"} "${EXTRA[@]}" --cache-key="&d~&r~&a~&I~$name" ${initrd:+--initrd="$initrd"} \
		--environment="SAFESPACE_COMBINATION=$name" --output-directory="$dir" ${MKOSI_ARGS[@]+"${MKOSI_ARGS[@]}"} build) || return 1
	[[ -n $initrd ]] || cp "$dir/initrd.cpio.zst" "$PARTS/initrd.cpio.zst" || return 1
	(builds_finalize "$dir" "$VERSION")
}
# Whether NAME has an installed image in mkosi's cache (and no -f asks for a new one).
cached() { # NAME
	compgen -G "$HERE/mkosi.cache/*~main~$1.manifest" >/dev/null || return 1
	local a
	for a in ${MKOSI_ARGS[@]+"${MKOSI_ARGS[@]}"}; do [[ $a == -f* || $a == --force ]] && return 1; done
	return 0
}
first=${COMBO_NAMES[0]}
build_combination "$first" "${COMBO_GROUPS[0]}" "$PARTS/$first" ||
	die "the build of $first failed (parts in ${PARTS#"$HERE"/})"
# The others: those without a cached image one after the other, then the
# rest side by side.
JOBS=$(($(free_gib /var/tmp) / 8))
((JOBS >= 1)) || JOBS=1
pids=() names=()
for i in "${!COMBO_NAMES[@]}"; do
	((i > 0)) || continue
	n=${COMBO_NAMES[i]}
	if ! cached "$n"; then
		build_combination "$n" "${COMBO_GROUPS[i]}" "$PARTS/$n" "$PARTS/initrd.cpio.zst" ||
			die "the build of $n failed (parts in ${PARTS#"$HERE"/})"
	fi
done
for i in "${!COMBO_NAMES[@]}"; do
	((i > 0)) || continue
	n=${COMBO_NAMES[i]}
	[[ ! -d $PARTS/$n ]] || continue
	while (($(jobs -rp | wc -l) >= JOBS)); do wait -n || true; done
	build_combination "$n" "${COMBO_GROUPS[i]}" "$PARTS/$n" "$PARTS/initrd.cpio.zst" >"$PARTS/$n.log" 2>&1 &
	pids+=($!) names+=("$n")
done
((${#pids[@]} == 0)) || log "building ${names[*]} side by side (up to $JOBS at a time; logs in ${PARTS#"$HERE"/}/NAME.log)"
failed=()
for i in "${!pids[@]}"; do
	wait "${pids[i]}" || failed+=("${names[i]}")
	cat "$PARTS/${names[i]}.log"
done
((${#failed[@]} == 0)) || die "the build of ${failed[*]} failed (parts and logs in ${PARTS#"$HERE"/})"
dirs=()
for n in "${COMBO_NAMES[@]}"; do dirs+=("$PARTS/$n"); done
rm -f "$PARTS/initrd.cpio.zst"

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
	builder="$(uname -n)" users="$USERS_FILE" policy="$(settings_policy)"
# The release file, signed by the db key (safespace update checks it).
builds_sign_release "$OUTDIR" "$KEYS_SB_DIR/db/db.pem" "$KEYS_SB_DIR/db/db.key" ||
	die "signing the release file with the db key failed"
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
