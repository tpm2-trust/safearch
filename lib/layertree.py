"""A layer's tree, and the proof that the layers stack to the combination.

  layertree.py diff LOWER FULL LIST
      the paths of FULL a read-only overlay on LOWER must carry: every path that
      is new or differs (type, mode, owner, content, xattrs), with the
      directories above it; NUL separated into LIST, for tar --no-recursion.
      Exit 2: FULL lacks a path LOWER has (a layer cannot delete: overlayfs
      would need a whiteout, and the layer below would show through);
      exit 3: the layer touches the kernel (usr/lib/modules: one kernel, the
      base's, for every combination).
  layertree.py compare A B
      A and B are the same tree; exit 1 with the differences.

The contents of var/, efi/ and boot/ are not part of a root (mkosi.repart:
ExcludeFilesTarget=; /var is the factory copy in /usr) and are left out; the
directories themselves count. Modification times do not count: the same file
built twice is the same file. Used by build.sh (lib/layers.sh) and tests/run.sh.
"""
import hashlib
import os
import stat
import sys

EMPTY = ("var", "efi", "boot")
KERNEL = ("usr/lib/modules",)


def meta(path):
    st = os.lstat(path)
    try:
        xattrs = tuple(sorted((n, os.getxattr(path, n, follow_symlinks=False))
                              for n in os.listxattr(path, follow_symlinks=False)))
    except OSError:
        xattrs = ()
    if stat.S_ISREG(st.st_mode):
        h = hashlib.sha256()
        with open(path, "rb") as f:
            for block in iter(lambda: f.read(1 << 20), b""):
                h.update(block)
        content = h.hexdigest()
    elif stat.S_ISLNK(st.st_mode):
        content = os.readlink(path)
    elif stat.S_ISCHR(st.st_mode) or stat.S_ISBLK(st.st_mode):
        content = st.st_rdev
    else:
        content = ""
    return (stat.S_IFMT(st.st_mode), stat.S_IMODE(st.st_mode), st.st_uid, st.st_gid, content, xattrs)


def walk(root):
    """(relative path, path) of every entry below root, the contents of EMPTY left out."""
    for d, dirs, files in os.walk(root):
        rel_d = os.path.relpath(d, root)
        if rel_d in EMPTY:
            dirs[:] = []
            continue
        for n in dirs + files:
            p = os.path.join(d, n)
            yield os.path.relpath(p, root), p


def under(rel, tops):
    return any(rel == t or rel.startswith(t + "/") for t in tops)


def diff(lower, full, out):
    want, deleted, kernel = set(), [], []
    for rel, p in walk(full):
        q = os.path.join(lower, rel)
        if not os.path.lexists(q) or meta(q) != meta(p):
            if under(rel, KERNEL):
                kernel.append(rel)
            want.add(rel)
            parent = os.path.dirname(rel)
            while parent:
                want.add(parent)
                parent = os.path.dirname(parent)
    for rel, _ in walk(lower):
        if not os.path.lexists(os.path.join(full, rel)):
            deleted.append(rel)
    with open(out, "wb") as f:
        for rel in sorted(want):
            f.write(rel.encode() + b"\0")
    for rel in deleted[:20]:
        print(f"deleted: /{rel}", file=sys.stderr)
    for rel in kernel[:20]:
        print(f"kernel: /{rel}", file=sys.stderr)
    if deleted:
        return 2
    if kernel:
        return 3
    print(f"{len(want)} paths")
    return 0


def compare(a, b):
    ma = {rel: meta(p) for rel, p in walk(a)}
    mb = {rel: meta(p) for rel, p in walk(b)}
    names = ("type", "mode", "owner", "group", "content", "xattrs")
    bad = sorted(set(ma) ^ set(mb)) + sorted(r for r in set(ma) & set(mb) if ma[r] != mb[r])
    for rel in bad[:30]:
        if rel not in ma or rel not in mb:
            print(f"only in {'the first' if rel in ma else 'the second'}: /{rel}", file=sys.stderr)
        else:
            what = ",".join(n for n, x, y in zip(names, ma[rel], mb[rel]) if x != y)
            print(f"differs ({what}): /{rel}", file=sys.stderr)
    if bad:
        return 1
    print(f"{len(ma)} entries, the same")
    return 0


if __name__ == "__main__":
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd == "diff" and len(args) == 3:
        sys.exit(diff(*args))
    if cmd == "compare" and len(args) == 2:
        sys.exit(compare(*args))
    sys.exit("usage: layertree.py diff LOWER FULL LIST | compare A B")
