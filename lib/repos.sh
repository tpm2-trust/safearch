# Package source for the image: which Arch Linux snapshot, from which mirror.
# Sourced by build.sh and update-snapshot.sh; expects die() and log(), and
# SNAPSHOT and MIRROR from safespace.conf (lib/conf.sh).
#
#   SNAPSHOT=YYYY/MM/DD  pinned Arch Linux Archive day
#   SNAPSHOT=latest      the current repositories, nothing pinned
#   MIRROR=              empty: mkosi's default for the SNAPSHOT kind
#   MIRROR=URL           base URL; mkosi appends the repository path itself
#
# URL mkosi builds per repository ($repo = core, extra; $arch = x86_64):
#   SNAPSHOT=date    ${MIRROR:-https://archive.archlinux.org}/repos/<date>/$repo/os/$arch
#   SNAPSHOT=latest  ${MIRROR:-https://fastly.mirror.pkgbuild.com}/$repo/os/$arch
# So with a date MIRROR must be an Arch Linux Archive mirror (has /repos/),
# with latest a normal pacman mirror, given as the part of its mirrorlist
# entry before /$repo/os/$arch (https://ftp.fau.de/archlinux).

REPOS_DEFAULT_ARCHIVE=https://archive.archlinux.org
REPOS_DEFAULT_MIRROR=https://fastly.mirror.pkgbuild.com
REPOS_ARCH=x86_64

# repos_validate: SNAPSHOT and MIRROR as mkosi takes them (MIRROR without a
# trailing slash).
repos_validate() {
	[[ $SNAPSHOT == latest || $SNAPSHOT =~ ^[0-9]{4}/[0-9]{2}/[0-9]{2}$ ]] ||
		die "SNAPSHOT must be YYYY/MM/DD or latest, got '$SNAPSHOT' (safespace.conf)"
	if [[ -n $MIRROR ]]; then
		[[ $MIRROR != *'$'* ]] ||
			die "MIRROR must not contain \$repo/\$arch, mkosi appends the repository path itself: $MIRROR"
		[[ $MIRROR =~ ^https?://[^[:space:]/]+(/[^[:space:]]*)?$ ]] ||
			die "MIRROR must be an http:// or https:// URL: $MIRROR"
		MIRROR=${MIRROR%/}
	fi
	return 0
}

# repos_mkosi_args: print the mkosi options for SNAPSHOT/MIRROR, one per line.
repos_mkosi_args() {
	[[ $SNAPSHOT == latest ]] || printf '%s\n' "--snapshot=$SNAPSHOT"
	[[ -z $MIRROR ]] || printf '%s\n' "--mirror=$MIRROR"
}

# repos_base: the repository root that $repo/os/$arch is appended to.
repos_base() {
	if [[ $SNAPSHOT == latest ]]; then
		printf '%s\n' "${MIRROR:-$REPOS_DEFAULT_MIRROR}"
	else
		printf '%s\n' "${MIRROR:-$REPOS_DEFAULT_ARCHIVE}/repos/$SNAPSHOT"
	fi
}

# repos_describe: one line for the log.
repos_describe() {
	if [[ $SNAPSHOT == latest ]]; then
		printf 'latest packages from %s\n' "${MIRROR:-$REPOS_DEFAULT_MIRROR (mkosi default)}"
	else
		printf 'snapshot %s from %s\n' "$SNAPSHOT" "${MIRROR:-$REPOS_DEFAULT_ARCHIVE (mkosi default)}"
	fi
}

# repos_check: fail early, with the expected URL layout, if the mirror does
# not serve core.db where mkosi will look for it.
repos_check() {
	local url
	url="$(repos_base)/core/os/$REPOS_ARCH/core.db"
	curl -fsSL --max-time 30 -o /dev/null -r 0-0 "$url" && return 0
	if [[ $SNAPSHOT == latest ]]; then
		die "mirror check failed: $url
  With SNAPSHOT=latest, MIRROR is a normal pacman mirror without /\$repo/os/\$arch,
  e.g. MIRROR=https://ftp.fau.de/archlinux"
	else
		die "mirror check failed: $url
  With SNAPSHOT=<date>, MIRROR has to be an Arch Linux Archive mirror that serves
  <MIRROR>/repos/$SNAPSHOT/\$repo/os/\$arch. Normal pacman mirrors have no /repos/;
  for those use SNAPSHOT=latest, or leave MIRROR empty for $REPOS_DEFAULT_ARCHIVE."
	fi
}
