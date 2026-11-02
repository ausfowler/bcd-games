#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Mobile Claw Deck (MCD), a fork of BCD (https://github.com/thebcd69/bcd-games) by ausfowler.
# Added 2026-11-02. Includes work from BCD by thebcd69.
"""MCD Cloud (app/MCDCloud: OpenNOW's GeForce NOW engine as a Swift package) is wired in as built:

  1. The package: Swift 5 tools (OpenNOW builds in Swift 5 mode), iOS 17, one library product
     "MCDCloud" over OpenSSL, usrsctp and WebRTC binary targets, each an iPhone-only xcframework.
  2. The vendored sources match UPSTREAM.md: every patch tools/mcd-cloud-vendor.py lists is in, the
     only @main is OpenNOW's own under #if OPENNOW_STANDALONE_APP, and nothing writes Documents.
  3. OpenSSL's headers include each other through the framework (no <openssl/...> left).
  4. The Xcode project: a local package reference to MCDCloud, the Madeira target depends on its
     product and links it, and the project is object version 60 (XCLocalSwiftPackageReference).
  5. Only MCD's engine-bound file imports MCDCloud; the preview tool keeps it out; Settings › Cloud
     is wired into BCDSettingsLive.swift's custom pages.
  6. The symbol guard passes on the libraries here (llvm-nm), and CI runs it, fatally, before the
     archive.
  7. The licence texts the app carries are there, and the notices name the four components.
"""
import importlib.util
import re
import shutil
import subprocess
import sys
from pathlib import Path

R = Path(__file__).resolve().parents[2]
PKG = R / "app/MCDCloud"
failed = False


def check(cond, what):
    global failed
    print(("ok   " if cond else "FAIL ") + what)
    if not cond:
        failed = True


manifest = (PKG / "Package.swift").read_text()
check(manifest.startswith("// swift-tools-version:5.9") and ".iOS(.v17)" in manifest
      and '.library(name: "MCDCloud", targets: ["MCDCloud"])' in manifest
      and all(f'.binaryTarget(name: "{n}", path: "Frameworks/{n}.xcframework")' in manifest for n in ("OpenSSL", "usrsctp", "WebRTC")),
      "the package: Swift 5 tools, iOS 17, the MCDCloud library over three binary targets")
for name in ("OpenSSL", "usrsctp", "WebRTC"):
    xc = PKG / "Frameworks" / f"{name}.xcframework"
    slices = sorted(p.name for p in xc.iterdir() if p.is_dir())
    check(slices == ["ios-arm64"], f"{name}.xcframework is iPhone-only ({slices})")

spec = importlib.util.spec_from_file_location("vendor", R / "tools/mcd-cloud-vendor.py")
vendor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vendor)
sources = PKG / "Sources/MCDCloud/OpenNOW"
upstream = (PKG / "UPSTREAM.md").read_text()
for name, old, new, why in vendor.PATCHES:
    text = (sources / name).read_text()
    check(new in text and why in upstream, f"patch in {name}: {why[:60]}")
mains = sorted(str(p.relative_to(sources)) for p in sources.rglob("*.swift")
               if any(line.strip().startswith("@main") for line in p.read_text().splitlines()))
app_entry = (sources / "OpenNOWiOSApp.swift").read_text()
check(mains == ["OpenNOWiOSApp.swift"] and app_entry.index("#if OPENNOW_STANDALONE_APP") < app_entry.index("@main"),
      "the only @main is OpenNOW's, under #if OPENNOW_STANDALONE_APP")
check(not any(".documentDirectory" in p.read_text() for p in (PKG / "Sources").rglob("*.swift")),
      "nothing in MCD Cloud writes Documents (the folder people see in Files)")

headers = PKG / "Frameworks/OpenSSL.xcframework/ios-arm64/OpenSSL.framework/Headers"
left = [p.name for p in headers.rglob("*.h") if vendor.INCLUDE_OPENSSL.search(p.read_text(encoding="latin-1"))]
check(not left and "#include <OpenSSL/openssl/ssl.h>" in (headers / "OpenSSL.h").read_text(),
      "OpenSSL's headers include each other through the framework")

pbx = (R / "app/Madeira.xcodeproj/project.pbxproj").read_text()
check("\tobjectVersion = 60;\n" in pbx, "the project is object version 60")
check(re.search(r'isa = XCLocalSwiftPackageReference;\s*relativePath = MCDCloud;', pbx) is not None
      and re.search(r'packageReferences = \(\s*A8000F05 /\* XCLocalSwiftPackageReference "MCDCloud" \*/,', pbx) is not None,
      "the project references the local package app/MCDCloud")
target = pbx[pbx.index("A5000001 /* Madeira */ = {"):]
target = target[:target.index("\n\t\t};\n")]
frameworks = pbx[pbx.index("A3000001 /* Frameworks */ = {"):]
frameworks = frameworks[:frameworks.index("\n\t\t};\n")]
check("A8000F04 /* MCDCloud */" in target and "A1000F03 /* MCDCloud in Frameworks */" in frameworks
      and "A1000F03 /* MCDCloud in Frameworks */ = {isa = PBXBuildFile; productRef = A8000F04 /* MCDCloud */; };" in pbx,
      "the Madeira target depends on MCDCloud and links it")

app = R / "app/Madeira"
importers = sorted(p.name for p in app.rglob("*.swift") if re.search(r"^import MCDCloud$", p.read_text(), re.M))
check(importers == ["MCDCloudLive.swift"], f"only MCDCloudLive.swift imports MCDCloud ({importers})")
check('ENGINE_BOUND |= {"MCDCloudLive.swift"}' in (R / "tools/ui-preview.py").read_text(),
      "the preview tool keeps MCDCloudLive.swift out")
check(".cloud: { AnyView(MCDCloudLiveSection(backHook: BCDSettingsSectionBack.shared.hook)) }" in (app / "BCDSettingsLive.swift").read_text(),
      "Settings › Cloud is wired in as a custom page")

nm = next((t for t in ("llvm-nm", "llvm-nm-18", "llvm-nm-17") if shutil.which(t)), None)
if nm:
    guard = subprocess.run([sys.executable, str(R / "tools/mcd-cloud-symbol-guard.py"), nm], capture_output=True, text=True)
    check(guard.returncode == 0, "the symbol guard passes on the libraries here: " + guard.stdout.strip().splitlines()[-1][:120])
else:
    print("note: no llvm-nm here; the symbol guard is not run (CI runs it before the archive)")
workflow = (R / ".github/workflows/build-ipa.yml").read_text()
step = workflow[workflow.index("      - name: Guard MCD Cloud's libraries against duplicate symbols"):]
step = step[:step.index("\n\n")]
check('run: python3 tools/mcd-cloud-symbol-guard.py --ci "$(xcrun -f nm)"' in step and "continue-on-error" not in step
      and workflow.index("Guard MCD Cloud's libraries") < workflow.index("      - name: Archive (unsigned)"),
      "CI runs the guard, fatally, before the archive")

legal = app / "legal/LICENSES"
check(all((legal / n).is_file() for n in ("MIT-OpenNOW.txt", "Apache-2.0-OpenSSL.txt", "BSD-3-usrsctp.txt", "BSD-3-WebRTC.txt")),
      "the app carries OpenNOW's, OpenSSL's, usrsctp's and WebRTC's licence texts")
notices = (R / "THIRD-PARTY-NOTICES.md").read_text()
check(all(f"| **{n}**" in notices for n in ("OpenNOW", "OpenSSL", "usrsctp", "WebRTC.framework")),
      "THIRD-PARTY-NOTICES.md names the four components")

print("check-mcd-cloud: " + ("FAIL" if failed else "PASS"))
sys.exit(1 if failed else 0)
