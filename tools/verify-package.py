#!/usr/bin/env python3
"""Check that every asset driver.xml references is actually in the .c4z.

Broken asset paths fail silently: Composer substitutes its generic logo and
Navigator falls back to a default icon, with nothing in any log. A single wrong
path can therefore go unnoticed indefinitely.

The trap is that both path forms resolve relative to the c4z's `www/` directory,
not its root:

    <small image_source="c4z">icons/device_sm.png</small>   ->  www/icons/device_sm.png
    controller://driver/<name>/icons/device_70.png          ->  www/icons/device_70.png

    python3 tools/verify-package.py build/<driver>.c4z
"""

import os
import re
import sys
import zipfile


def main():
    if len(sys.argv) < 2:
        print("usage: verify-package.py <package.c4z>", file=sys.stderr)
        return 2

    pkg = sys.argv[1]
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
    xml = open(os.path.join(root, "driver.xml"), encoding="utf-8").read()

    with zipfile.ZipFile(pkg) as z:
        names = set(z.namelist())

    lua = open(os.path.join(root, "driver.lua"), encoding="utf-8").read()

    refs = set()
    # Composer driver-list and proxy images.
    refs |= set(re.findall(r'image_source="c4z"[^>]*>([^<]+)</(?:small|large)>', xml))
    refs |= set(re.findall(r'(?:small|large)_image="([^"]+)"', xml))
    # Navigator assets.
    refs |= set(re.findall(r"controller://driver/[^/]+/([^<\"]+)", xml))
    # Documentation page.
    refs |= {m for m in re.findall(r'<documentation file="([^"]+)"', xml)}

    # driver.lua builds icon paths at runtime from a prefix and a size, so the
    # literal strings never appear anywhere. Expand them instead: this is where
    # a missing size would otherwise go unnoticed until a row rendered blank.
    sizes = re.search(r"IMAGE_SIZES\s*=\s*\{([^}]*)\}", lua)
    if sizes:
        sizes = [int(n) for n in re.findall(r"\d+", sizes.group(1))]
        prefixes = set(re.findall(r"ImageListForAsset\('([^']+)'\)", lua))
        prefixes |= set(re.findall(r"icons/([a-z_]+?)_' \.\. size", lua))
        for p in prefixes:
            for z in sizes:
                refs.add(f"icons/{p}_{z}.png")

    # Composer derives the asset namespace from the package filename, so a
    # mismatch breaks every controller:// reference while leaving remote URLs
    # working -- which looks like an icon problem, not a packaging one.
    base = os.path.basename(pkg)[:-4] if pkg.endswith(".c4z") else os.path.basename(pkg)
    namespaces = set(re.findall(r"controller://driver/([^/]+)/", xml))
    namespaces |= set(re.findall(r"controller://driver/([^/]+)/", lua))
    wrong_ns = sorted(n for n in namespaces if n != base)

    missing = sorted(r for r in refs if r not in names and "www/" + r not in names)

    print(f"checked {len(refs)} asset references in {os.path.basename(pkg)}")

    if wrong_ns:
        print(f"PACKAGE NAME MISMATCH: package is '{base}.c4z' but assets reference "
              f"{', '.join(repr(n) for n in wrong_ns)}", file=sys.stderr)
        print("  controller:// paths only resolve when the .c4z is named <namespace>.c4z",
              file=sys.stderr)
        return 1

    if missing:
        print(f"MISSING {len(missing)}:", file=sys.stderr)
        for m in missing:
            print(f"  {m}  (looked for '{m}' and 'www/{m}')", file=sys.stderr)
        return 1

    print("all asset references resolve")
    return 0


if __name__ == "__main__":
    sys.exit(main())
