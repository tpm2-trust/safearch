# /var is a tmpfs at runtime (systemd.volatile=state). factory_var ROOT moves
# everything built into ROOT/var (homes, pacman's database, package state) to
# the verified factory copy, ROOT/usr/share/factory/var, which
# safespace-var-factory.service copies into the tmpfs on every boot; caches,
# logs and the sync databases are dropped. One code path for mkosi.finalize
# (an image) and build.sh (a layer's tree, after the layers above it were built
# on it: they need the package database where pacman looks for it).
factory_var() { # ROOT
	local root=$1 factory=$1/usr/share/factory/var
	rm -rf "$factory"
	install -d "$factory"
	rm -rf "$root"/var/cache/* "$root"/var/log/* "$root"/var/tmp/* "$root"/var/lib/pacman/sync
	cp -a "$root/var/." "$factory/"
	find "$root/var" -mindepth 1 -delete
	echo "safespace: /var moved to /usr/share/factory/var ($(du -sh "$factory" | cut -f1))"
}
