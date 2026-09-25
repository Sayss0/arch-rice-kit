#!/usr/bin/env python3
"""Rebuild a pacman package file from an INSTALLED package (like the old `bacman`).

Reads /var/lib/pacman/local/<name>-<ver>/{desc,files,install,mtree}, writes
<outdir>/<name>-<ver>-<arch>.pkg.tar.zst containing .PKGINFO (+ .INSTALL,
.MTREE) and every file the package owns, owned root:root unless the package's
own mtree says otherwise.  No root needed as long as the files are readable;
a package with ANY unreadable file is refused (exit 3) so a broken copy can
never ship.

usage: mkpkg-from-installed.py <pkgname> <outdir>
"""
import gzip, io, os, subprocess, sys, tarfile, time

LOCAL = "/var/lib/pacman/local"


def find_entry(name):
    for d in os.listdir(LOCAL):
        p = os.path.join(LOCAL, d)
        desc = os.path.join(p, "desc")
        if os.path.isfile(desc):
            with open(desc) as f:
                lines = f.read().split("\n")
            if "%NAME%" in lines and lines[lines.index("%NAME%") + 1] == name:
                return p
    return None


def parse_sections(path):
    out, key = {}, None
    with open(path) as f:
        for line in f.read().split("\n"):
            if line.startswith("%") and line.endswith("%"):
                key = line.strip("%")
                out[key] = []
            elif line and key:
                out[key].append(line)
    return out


def mtree_owners(entry):
    """path -> (uid, gid) from the package's own mtree (only non-root ones)."""
    owners = {}
    p = os.path.join(entry, "mtree")
    if not os.path.exists(p):
        return owners
    uid, gid = 0, 0
    with gzip.open(p, "rt") as f:
        for line in f:
            line = line.rstrip("\n")
            if line.startswith("/set "):
                for kv in line.split()[1:]:
                    k, _, v = kv.partition("=")
                    if k == "uid": uid = int(v)
                    if k == "gid": gid = int(v)
                continue
            if not line.startswith("./"):
                continue
            parts = line.split()
            path = parts[0][2:]
            u, g = uid, gid
            for kv in parts[1:]:
                k, _, v = kv.partition("=")
                if k == "uid": u = int(v)
                if k == "gid": g = int(v)
            # mtree escapes spaces etc. as \ooo octal
            path = path.encode().decode("unicode_escape").encode("latin-1").decode()
            if (u, g) != (0, 0):
                owners[path] = (u, g)
    return owners


def main():
    name, outdir = sys.argv[1], sys.argv[2]
    entry = find_entry(name)
    if not entry:
        print(f"{name}: not installed", file=sys.stderr); sys.exit(2)
    desc = parse_sections(os.path.join(entry, "desc"))
    files = parse_sections(os.path.join(entry, "files"))
    ver, arch = desc["VERSION"][0], desc["ARCH"][0]

    pk = [f"# Rebuilt from the installed package by mkpkg-from-installed.py {time.strftime('%F')}",
          f"pkgname = {name}", f"pkgbase = {desc.get('BASE', [name])[0]}", f"pkgver = {ver}"]
    for key, field in [("DESC", "pkgdesc"), ("URL", "url")]:
        for v in desc.get(key, []): pk.append(f"{field} = {v}")
    pk.append(f"builddate = {desc.get('BUILDDATE', ['0'])[0]}")
    pk.append(f"packager = {desc.get('PACKAGER', ['Unknown Packager'])[0]}")
    pk.append(f"size = {desc.get('SIZE', ['0'])[0]}")
    pk.append(f"arch = {arch}")
    for key, field in [("LICENSE", "license"), ("REPLACES", "replaces"), ("GROUPS", "group"),
                       ("CONFLICTS", "conflict"), ("PROVIDES", "provides"), ("DEPENDS", "depend"),
                       ("OPTDEPENDS", "optdepend"), ("XDATA", "xdata")]:
        for v in desc.get(key, []): pk.append(f"{field} = {v}")
    for b in files.get("BACKUP", []):
        pk.append(f"backup = {b.rsplit(chr(9), 1)[0]}")
    pkginfo = ("\n".join(pk) + "\n").encode()

    owners = mtree_owners(entry)
    paths = files.get("FILES", [])
    bad = [p for p in paths if not p.endswith("/") and not os.path.islink("/" + p)
           and not os.access("/" + p, os.R_OK)]
    missing = [p for p in paths if not os.path.lexists("/" + p.rstrip("/"))]
    if bad or missing:
        for p in bad: print(f"{name}: UNREADABLE /{p}", file=sys.stderr)
        for p in missing: print(f"{name}: MISSING /{p}", file=sys.stderr)
        sys.exit(3)

    os.makedirs(outdir, exist_ok=True)
    out = os.path.join(outdir, f"{name}-{ver}-{arch}.pkg.tar.zst")
    zstd = subprocess.Popen(["zstd", "-q", "-T0", "-15", "-f", "-o", out], stdin=subprocess.PIPE)
    with tarfile.open(fileobj=zstd.stdin, mode="w|", format=tarfile.PAX_FORMAT) as tar:
        def add_bytes(arcname, data, mode=0o644):
            ti = tarfile.TarInfo(arcname); ti.size = len(data); ti.mode = mode
            ti.mtime = int(time.time()); ti.uname = ti.gname = "root"
            tar.addfile(ti, io.BytesIO(data))
        add_bytes(".PKGINFO", pkginfo)
        inst = os.path.join(entry, "install")
        if os.path.exists(inst):
            add_bytes(".INSTALL", open(inst, "rb").read())
        mt = os.path.join(entry, "mtree")
        if os.path.exists(mt):
            add_bytes(".MTREE", open(mt, "rb").read())
        for p in paths:
            rel = p.rstrip("/")
            ti = tar.gettarinfo("/" + rel, arcname=rel)
            u, g = owners.get(rel, (0, 0))
            ti.uid, ti.gid = u, g
            ti.uname = "root" if u == 0 else ""
            ti.gname = "root" if g == 0 else ""
            if ti.isreg():
                with open("/" + rel, "rb") as fh:
                    tar.addfile(ti, fh)
            else:
                tar.addfile(ti)
    zstd.stdin.close()
    if zstd.wait() != 0:
        print(f"{name}: zstd failed", file=sys.stderr); sys.exit(4)
    print(out)


if __name__ == "__main__":
    main()
