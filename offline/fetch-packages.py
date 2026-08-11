#!/usr/bin/env python3
"""Fetch Debian packages (.deb) with their dependencies for offline install.

Works on any OS with Python 3 (stdlib only, no internet-restricted tools):
downloads Packages indexes from a Debian mirror, resolves the dependency
closure of the seed packages and downloads every .deb into ./debs/.

Usage:
    python3 fetch-packages.py [--suite trixie] [--arch amd64] [--out debs]

Seeds can be overridden with positional args:
    python3 fetch-packages.py linuxcnc-uspace linux-image-rt-amd64

Everything downloaded comes from public Debian archives. This script is part
of the mach3-to-linuxcnc project (MIT).
"""

import argparse
import gzip
import io
import lzma
import os
import re
import sys
import urllib.request
from collections import OrderedDict
from urllib.error import HTTPError

DEFAULT_SEEDS = [
    "linuxcnc-uspace",
    "linuxcnc-uspace-dev",
    "linuxcnc-doc-en",
    "linux-image-rt-amd64",
    "openbox",
    "lightdm",
    "lightdm-gtk-greeter",
    "alacritty",
    "xterm",
    "thunar",
    "gvfs-backends",
    "udisks2",
    "policykit-1",
    "neovim",
    "libnotify-bin",
    "xinit",
    "xauth",
    "x11-xserver-utils",
    "xserver-xorg-core",
    "xserver-xorg-input-all",
    "xserver-xorg-video-fbdev",
    "fonts-dejavu-core",
]

ARCH_ANY = re.compile(r":any$")
VERSION_OP = re.compile(r"^([^\(]+)(?:\(([<>=~]+)\s*([^)]+)\))?$")
# operators that require the installed version to be >= index version
OP_MEANS_GTE = {
    ">=": True,
    ">>": True,
    "=": False,
    "==": False,
    "<=": False,
    "<<": False,
}


def parse_stanzas(text):
    """Yield dicts of Debian control paragraphs."""
    pkg = {}
    for line in text.splitlines():
        if not line.strip():
            if pkg:
                yield pkg
                pkg = {}
            continue
        if line.startswith(" ") or line.startswith("\t"):
            # continuation of previous field
            pkg[last_field] += " " + line.strip()
            continue
        key, _, value = line.partition(":")
        pkg[key.strip()] = value.strip()
        last_field = key.strip()
    if pkg:
        yield pkg


def split_deps(deps_str):
    """Split a Depends/Recommends field into a list of (name, op, ver) triples.
    Keeps alternatives as a flat list; caller must group by '|'."""
    if not deps_str:
        return []
    out = []
    for chunk in re.split(r",\s*", deps_str.strip()):
        m = VERSION_OP.match(chunk.strip())
        if m:
            out.append((m.group(1).strip(), m.group(2), m.group(3)))
        else:
            out.append((chunk.strip(), None, None))
    return out


def load_packages(mirror, suite, arch, session_dir):
    """Return {name: entry} merging binary-<arch> and binary-all indexes."""
    index = {}
    comps = [f"binary-{arch}", "binary-all"]
    for comp in comps:
        url = f"{mirror}/dists/{suite}/main/{comp}/Packages.xz"
        raw = fetch_url(url, os.path.join(session_dir, f"Packages-{comp}.xz"))
        if raw is None:
            url = url[:-3] + ".gz"
            raw = fetch_url(url, os.path.join(session_dir, f"Packages-{comp}.gz"))
        if raw is None:
            continue
        try:
            data = lzma.decompress(raw)
        except lzma.LZMAError:
            data = gzip.decompress(raw)
        text = data.decode("utf-8", errors="replace")
        for pkg in parse_stanzas(text):
            name = pkg["Package"]
            # prefer the arch-specific entry when both exist
            if name not in index or pkg.get("Architecture") == arch:
                index[name] = pkg
    return index


def fetch_url(url, cache_path=None):
    """Download url; cache to cache_path. Returns bytes or None on 404."""
    if cache_path and os.path.exists(cache_path):
        try:
            with open(cache_path, "rb") as f:
                return f.read()
        except OSError:
            pass
    req = urllib.request.Request(url)
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            data = resp.read()
    except HTTPError as e:
        if e.code == 404:
            return None
        raise
    if cache_path:
        tmp = cache_path + ".tmp"
        with open(tmp, "wb") as f:
            f.write(data)
        os.replace(tmp, cache_path)
    return data


def version_satisfied(op, constraint, version):
    """Very small version comparator. Assumes Debian version format.
    Returns True when op is None (no constraint) or when the constraint is met."""
    if not op or not constraint:
        return True
    if op in (">=", ">>"):
        # dependency wants index version >= constraint -> check index >= constraint
        return version_compare(version, constraint) >= 0
    if op in ("<=", "<<"):
        return version_compare(version, constraint) <= 0
    if op in ("=", "=="):
        return version_compare(version, constraint) == 0
    return True


def version_compare(a, b):
    """Compare two Debian version strings. Simplified but adequate for the
    package sets we deal with. Returns -1/0/1."""
    return simple_cmp(version_tokens(a), version_tokens(b))


def version_tokens(ver):
    ver = ver.split("-")[0]  # ignore debian revision for simplicity
    parts = re.findall(r"\d+|[a-zA-Z]+", ver)
    return parts


def simple_cmp(a, b):
    for x, y in zip(a, b):
        xn = x.isdigit()
        yn = y.isdigit()
        if xn and yn:
            xi, yi = int(x), int(y)
            if xi != yi:
                return -1 if xi < yi else 1
        elif xn != yn:
            return -1 if xn else 1
        elif x != y:
            return -1 if x < y else 1
    if len(a) == len(b):
        return 0
    return -1 if len(a) < len(b) else 1


def resolve_closure(seeds, index, with_recommends):
    """BFS over Depends/Recommends. Returns OrderedDict name->entry."""
    closure = OrderedDict()
    queue = list(seeds)
    provides = {}
    for name, entry in index.items():
        for prov in split_deps(entry.get("Provides", "")):
            provides.setdefault(prov[0], []).append(entry)

    while queue:
        name = queue.pop(0)
        name = ARCH_ANY.sub("", name)
        if name in closure:
            continue
        entry = index.get(name)
        if entry is None:
            # try providers (virtual package)
            providers = provides.get(name, [])
            entry = providers[0] if providers else None
            if entry is None:
                print(f"[warn] package '{name}' not found in index, skipping")
                continue
        # use the real package name as the key (a virtual package may be
        # provided by several real packages with the same .deb)
        real_name = entry.get("Package", name)
        closure[real_name] = entry
        # collect dependency strings: Depends + Pre-Depends (+ Recommends)
        raw = []
        raw += (entry.get("Pre-Depends") or "").split(",")
        raw += (entry.get("Depends") or "").split(",")
        if with_recommends:
            raw += (entry.get("Recommends") or "").split(",")
        for chunk in raw:
            chunk = chunk.strip()
            if not chunk:
                continue
            alts = [a.strip() for a in chunk.split("|")]
            for alt in alts:
                m = VERSION_OP.match(alt)
                alt_name, op, ver = (m.group(1).strip(), m.group(2), m.group(3)) if m else (alt, None, None)
                alt_name = ARCH_ANY.sub("", alt_name)
                alt_entry = index.get(alt_name)
                if alt_entry is None:
                    alt_entry = provides.get(alt_name, [None])[0]
                if alt_entry is not None and version_satisfied(op, ver, alt_entry.get("Version", "0")):
                    if alt_name not in closure:
                        queue.append(alt_name)
                    break
    return closure


def download(entry, mirror, out_dir):
    filename = entry["Filename"]
    name = os.path.basename(filename)
    url = f"{mirror}/{filename}"
    size = int(entry.get("Size", 0))
    dest = os.path.join(out_dir, name)
    if os.path.exists(dest) and os.path.getsize(dest) == size:
        print(f"  ok     {name}")
        return True
    tmp = dest + ".part"
    start = os.path.getsize(tmp) if os.path.exists(tmp) else 0
    headers = {"Range": f"bytes={start}-"} if start and size and start < size else {}
    req = urllib.request.Request(url, headers=headers)
    mode = "ab" if start else "wb"
    with urllib.request.urlopen(req, timeout=120) as resp:
        with open(tmp, mode) as f:
            while True:
                chunk = resp.read(1 << 16)
                if not chunk:
                    break
                f.write(chunk)
    if size and os.path.getsize(tmp) != size:
        print(f"  [err] {name}: size mismatch")
        return False
    os.replace(tmp, dest)
    print(f"  ok     {name}")
    return True


def main():
    ap = argparse.ArgumentParser(description="Download Debian packages + deps for offline install")
    ap.add_argument("--suite", default="trixie", help="Debian suite (default: trixie)")
    ap.add_argument("--arch", default="amd64", help="architecture (default: amd64)")
    ap.add_argument("--mirror", default="https://deb.debian.org/debian", help="Debian mirror root")
    ap.add_argument("--out", default="debs", help="output directory (default: debs)")
    ap.add_argument("--no-recommends", action="store_true", help="do not pull Recommends")
    ap.add_argument("seeds", nargs="*", help="package seeds (default: full RA0306 stack)")
    args = ap.parse_args()

    seeds = args.seeds or DEFAULT_SEEDS
    os.makedirs(args.out, exist_ok=True)
    session_dir = os.path.join(args.out, ".index-cache")
    os.makedirs(session_dir, exist_ok=True)

    print(f"== Loading packages indexes ({args.suite}/{args.arch}) ...")
    index = load_packages(args.mirror, args.suite, args.arch, session_dir)
    print(f"   index: {len(index)} packages")

    print("== Resolving dependency closure ...")
    closure = resolve_closure(seeds, index, not args.no_recommends)
    print(f"   closure: {len(closure)} packages")

    total = 0
    for name in list(closure):
        entry = closure[name]
        total += int(entry.get("Size", 0))

    print(f"== Downloading ~{total/1e6:.0f} MB into {args.out}/")
    ok = True
    seen_files = set()
    for name in list(closure):
        entry = closure[name]
        if entry.get("Filename") in seen_files:
            continue
        seen_files.add(entry.get("Filename"))
        if not download(entry, args.mirror, args.out):
            ok = False

    manifest = os.path.join(args.out, "packages.txt")
    with open(manifest, "w") as f:
        for name in closure:
            entry = closure[name]
            f.write(f"{name}\t{entry.get('Version','?')}\t{entry.get('Filename','?')}\n")
    print(f"\nManifest: {manifest}")
    if not ok:
        sys.exit(1)
    print("Done. Copy debs/ + setup-machine.sh + dotfiles/ to the USB stick.")


if __name__ == "__main__":
    main()
