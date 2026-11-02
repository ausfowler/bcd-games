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
check(importers == ["MCDCloudCardsLive.swift", "MCDCloudLive.swift", "MCDCloudPlayLive.swift"], f"only the three engine-bound MCD Cloud files import MCDCloud ({importers})")
check('ENGINE_BOUND |= {"MCDCloudLive.swift", "MCDCloudCardsLive.swift", "MCDCloudPlayLive.swift"}' in (R / "tools/ui-preview.py").read_text(),
      "the preview tool keeps the three engine-bound files out")
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

# Phase 3: playing in the cloud.
mcd = PKG / "Sources/MCDCloud/MCD"
stream = (mcd / "MCDCloudStream.swift").read_text()
input_src = (sources / "NativeStreamInput.swift").read_text()
attach = input_src[input_src.index("    func attach() {\n        NotificationCenter.default.post"):]
attach = attach[:attach.index("\n    }\n")]
detach = input_src[input_src.index("    func detach() {"):]
detach = detach[:detach.index("\n    }\n")]
check(attach.index("post(name: MCDCloudInput.willAttach") < attach.index("refreshDevices()")
      and detach.rstrip().endswith("NotificationCenter.default.post(name: MCDCloudInput.didDetach, object: nil) // MCD: MCD's input code takes them back")
      and detach.index("valueChangedHandler = nil") < detach.index("MCDCloudInput.didDetach"),
      "OpenNOW says it takes the controllers before it sets a handler, and lets go after it has cleared them all")
check('public static let willAttach = Notification.Name("MCDCloud.inputWillAttach")' in stream
      and 'public static let didDetach = Notification.Name("MCDCloud.inputDidDetach")' in stream,
      "MCDCloudInput names both moments, public to the app")
live = (app / "MCDCloudPlayLive.swift").read_text()
check(all(f"forName: MCDCloudInput.{n}, object: nil, queue: nil)" in live for n in ("willAttach", "didDetach")),
      "MCD hears both at once, on the posting thread (a nil queue), before the stream goes on")
aside = live[live.index("private func stepAside()"):live.index("private func takeBack()")]
back = live[live.index("private func takeBack()"):live.index("nonisolated private static func onMain")]
check(all(s in aside for s in ("hub.setOn(false)", "GamepadInput.shared.setCloudHold(true)", "HardwareInput.shared.setCloudHold(true)"))
      and all(s in back for s in ("GamepadInput.shared.setCloudHold(false)", "HardwareInput.shared.setCloudHold(false)",
                                  "if hubWasOn { BCDControllerHub.shared.setOn(true) }")),
      "stepping aside lets go of the hub, XInput and keyboard and mouse; taking back restores all three")
gamepad = (app / "GamepadInput.swift").read_text()
refresh = gamepad[gamepad.index("@MainActor private func refreshControllers() {"):]
check(refresh.split("\n")[1].strip().startswith("guard !cloudHeld else { return }")
      and gamepad.count("installHandler(on: profile)") == 2 and "profile.valueChangedHandler = {" in gamepad
      and gamepad.count("valueChangedHandler = { [weak self]") == 1,
      "XInput attaches nothing while held, and puts one and the same handler back on every pad after")
hardware = (app / "HardwareInput.swift").read_text()
check(all(hardware[hardware.index(f"private func {f}("):].split("\n")[1].strip().startswith("guard !cloudHeld else { return }")
          for f in ("attachKeyboard", "attachMouse"))
      and 'inventory("cloud stream ended")' in hardware and "mouse.handlerQueue = .main" in hardware,
      "keyboard and mice: nothing attached while held, every device wired again after, the stream's on the main queue")
front = (app / "BCDFrontEnd.swift").read_text()
check(".modifier(MCDCloudHost(model: MCDCloudPlay.shared))" in front and "MCDCloudPlay.shared.play(game)" in front
      and "Streaming comes in the next MCD build" not in front,
      "Cloud on a card plays the game, on MCD's cloud screen over the shell")
check("MCDCloudPlayLive.shared.start()" in (app / "BCDLiveFrontEnd.swift").read_text(),
      "the live front end installs the cloud screen's actions")
host = (app / "MCDCloudPlay.swift").read_text()
sync = host[host.index("    private func sync() {"):]
sync = sync[:sync.index("\n    }\n")]
check("if focus.enabled == streaming { focus.enabled = !streaming }" in sync and "focus.openLayer(Self.layer)" in sync
      and ".onAppear { sync() }" in host and "onDisappear" not in host[host.index("struct MCDCloudHost"):host.index("struct MCDCloudButton")],
      "the interface reads no controller while the stream has it, and the screen takes it back whenever it shows (never closed on disappearing)")

# Phase 4: the stream's mode for the screen (MCDStreamFit), the same rule run here over OpenNOW's table.
store_src = (sources / "OpenNOWStore.swift").read_text()
table = re.findall(r'\.init\(value: "(\d+)x(\d+)", aspectRatio: "([\d:]+)", tier: "\d+", requiredPlan: \.(\w+)\)', store_src)
aspects = re.search(r'static let aspectRatioOptions = \[([^\]]+)\]', store_src).group(1).replace('"', "").replace(" ", "").split(",")
plans = {"free": 0, "priority": 1, "ultimate": 2}
import math
def fit(w, h, plan, max_fps):
    w, h = max(w, h), min(w, h)
    shape = w / h
    def ratio(a):
        x, y = a.split(":"); return float(x) / float(y)
    aspect = min(aspects, key=lambda a: abs(math.log(ratio(a) / shape)))   # first of equals, as Swift's min
    allowed = [(int(a), int(b)) for a, b, asp, p in table if asp == aspect and plans[p] <= plan]
    fitting = [s for s in allowed if s[0] <= w and s[1] <= h]
    pick = max(fitting, key=lambda s: s[0] * s[1]) if fitting else min(allowed, key=lambda s: s[0] * s[1])
    return aspect, f"{pick[0]}x{pick[1]}", 120 if plan >= 2 and max_fps >= 120 else 60
check(len(table) == 28 and aspects == ["16:9", "16:10", "4:3", "5:4", "20:9", "21:9", "24:10", "32:9"], "OpenNOW's mode table as MCDStreamFit reads it")
duo_open = fit(951 * 3, 669 * 3, 1, 120)
check(duo_open == ("4:3", "1600x1200", 60), f"the Duo's open screen (951x669 pt at 3x) on Performance: {duo_open}")
check(fit(951 * 3, 669 * 3, 2, 120) == ("4:3", "1600x1200", 120), "... on Ultimate, at 120 fps")
check(fit(932 * 3, 430 * 3, 1, 120) == ("20:9", "2400x1080", 60) and fit(932 * 3, 430 * 3, 0, 60) == ("20:9", "1600x720", 60),
      "an iPhone Pro Max: 20:9, 2400x1080 on Performance, 1600x720 free")
fit_src = (mcd / "MCDStreamFit.swift").read_text()
check("let fitting = allowed.filter { size($0).width <= width && size($0).height <= height }" in fit_src
      and "(plan >= .ultimate && maxFPS >= 120) ? 120 : 60" in fit_src, "MCDStreamFit is that rule")
check("settingsOverride: screen" in stream and 'guard settings.preferredResolution == "Auto" else { return nil }' in stream,
      "a new session asks for the screen's mode (unless a resolution was chosen by hand)")
check(stream.index("await store.refreshRemoteSessions()") < stream.index("await store.resumeSession(candidate: running)")
      < stream.index("await store.launch(game: request.game"),
      "a session the game already has is resumed as it runs, never ended for a new one at another size (folding: option A)")
cards = (app / "MCDCloudCards.swift").read_text()
check("static let sameSession: TimeInterval = 15 * 60" in cards and "opensOnCloud" in (app / "MCDHomeView.swift").read_text(),
      "a card opens on Cloud when the cloud is where it was last played")
for name, ident in (("MCDCloudPlay.swift", "A1000F08"), ("MCDCloudPlayLive.swift", "A1000F09")):
    check(f"{ident} /* {name} in Sources */," in pbx, f"{name} is built into the app")
check("NativeStreamPresentation {\n                StreamerView(" in stream and "QueueAdPlayerCard(ad: ad, compact: true)" in stream,
      "the stream and the queue ads are OpenNOW's own views")

print("check-mcd-cloud: " + ("FAIL" if failed else "PASS"))
sys.exit(1 if failed else 0)
