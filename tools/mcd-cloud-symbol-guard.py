#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Mobile Claw Deck (MCD), a fork of BCD (https://github.com/thebcd69/bcd-games) by ausfowler.
# Added 2026-11-02. Includes work from BCD by thebcd69.
"""Before the app links: MCD Cloud's static libraries (OpenSSL, usrsctp) and every other static
library the app links must not define one global name twice.

    python3 tools/mcd-cloud-symbol-guard.py [--ci] [nm]

(--ci: every library must be there, as it is in CI once they are built; nm defaults to `nm`.)

Two static libraries defining the same name either fail the link with "duplicate symbol" deep in a
long log, or, worse, link quietly with one library's calls bound to the other's code. GnuTLS and
OpenSSL did exactly that (tools/mcd-cloud-vendor.py renames OpenSSL's copies); this step proves,
on the real archives CI just built, that nothing of the kind is left, and names any clash before
the archive step starts. It exits non-zero, listing each shared name and the two libraries.
"""
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CLOUD = [ROOT / "app/MCDCloud/Frameworks/OpenSSL.xcframework/ios-arm64/OpenSSL.framework/OpenSSL",
         ROOT / "app/MCDCloud/Frameworks/usrsctp.xcframework/ios-arm64/usrsctp.framework/usrsctp"]
# What the Madeira target's Frameworks phase links (the "Verify all linked archives exist" list).
APP = [ROOT / "app/Madeira" / name for name in (
    "libgmp.a", "libgnutls.a", "libhogweed.a", "libnettle.a", "libntdll_unix.a", "libwin32u_unix.a",
    "libwineserver.a", "libdxmt_combined.a", "libmadeira_rppairing.a")]
APP += [ROOT / "FEX/build-ios" / name for name in (
    "FEXCore/Source/libFEXCore.a", "FEXCore/Source/libFEXCore_Base.a", "FEXCore/Source/libJemallocLibs.a",
    "External/cephes/libcephes_128bit.a", "External/fmt/libfmt.a", "External/SoftFloat-3e/libsoftfloat_3e.a",
    "External/xxhash/cmake_unofficial/libxxhash.a")]


def defined(nm, archive):
    result = subprocess.run([nm, "-g", "-U", "-j", str(archive)], capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(f"mcd-cloud-symbol-guard: {nm} could not read {archive}:\n{result.stderr.strip()}")
    return {line.strip() for line in result.stdout.splitlines()
            if line.strip() and not line.rstrip().endswith(":")}


def main():
    args = sys.argv[1:]
    ci = "--ci" in args
    args = [a for a in args if a != "--ci"]
    nm = args[0] if args else "nm"
    missing = [str(p) for p in CLOUD if not p.is_file()]
    if missing:
        sys.exit(f"mcd-cloud-symbol-guard: MCD Cloud's libraries are missing: {missing}")
    others = [p for p in APP if p.is_file()]
    absent = [str(p.relative_to(ROOT)) for p in APP if not p.is_file()]
    if absent and ci:
        # In CI every library is built before this step: one missing is a mistake, not a pass.
        sys.exit(f"mcd-cloud-symbol-guard: libraries the app links are missing: {absent}")
    if absent:
        print(f"mcd-cloud-symbol-guard: not built here, so not checked: {absent}")
    cloud = {p: defined(nm, p) for p in CLOUD}
    clashes = []
    names = list(cloud.items())
    for i, (a, a_syms) in enumerate(names):
        for b, b_syms in names[i + 1:]:
            clashes += [(s, a, b) for s in sorted(a_syms & b_syms)]
    for other in others:
        other_syms = defined(nm, other)
        for lib, syms in cloud.items():
            clashes += [(s, lib, other) for s in sorted(syms & other_syms)]
    if clashes:
        print(f"mcd-cloud-symbol-guard: {len(clashes)} global names are defined twice:")
        for name, a, b in clashes[:60]:
            print(f"  {name}: {a.name} and {b.name}")
        sys.exit(1)
    total = sum(len(s) for s in cloud.values())
    print(f"mcd-cloud-symbol-guard: {total} global names of OpenSSL and usrsctp, none defined by "
          f"any of the {len(others)} other static libraries the app links.")


if __name__ == "__main__":
    main()
