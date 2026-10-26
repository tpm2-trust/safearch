# aSSH (the submodule assh/, github.com/tpm2-trust/assh): the machine's host
# key in the TPM, certified by its CA (SECURITY.md, "Machine identity"). Built
# here on the build host, static, into the tree every root gets
# (mkosi.extra/usr/bin/assh, gitignored). Sourced by build.sh and
# tests/run.sh; expects die() and log().
#
#   assh_build OUT   build assh/cmd/assh into OUT
#
# The module cache stays in mkosi.cache/go (with the other caches; the
# modules are fetched once, checked against assh/go.sum); SAFESPACE_GOCACHE
# puts it elsewhere (tests/run.sh, which touches nothing in the checkout). Go from the build
# host, never a toolchain it would download (GOTOOLCHAIN=local).

assh_build() { # OUT
	local out=$1 src=$HERE/assh cache=${SAFESPACE_GOCACHE:-$HERE/mkosi.cache/go}
	[[ -f $src/go.mod ]] || die "assh/ is empty: git submodule update --init assh"
	command -v go >/dev/null || die "go not found (pacman -S go): aSSH is built on the build host"
	mkdir -p "$cache" "$(dirname "$out")"
	(cd "$src" && env GOTOOLCHAIN=local GOFLAGS=-mod=readonly CGO_ENABLED=0 \
		GOMODCACHE="$cache/mod" GOCACHE="$cache/build" GOPATH="$cache/path" \
		go build -trimpath -ldflags=-s -o "$out" ./cmd/assh) ||
		die "building aSSH failed (assh/: go version $(go env GOVERSION), go.mod wants $(sed -n 's/^go //p' "$src/go.mod"))"
	"$out" help >/dev/null 2>&1 || die "$out does not run"
	log "aSSH $(git -c safe.directory="$src" -C "$src" describe --always --dirty 2>/dev/null || echo '?'): $(du -h "$out" | cut -f1) static"
}
