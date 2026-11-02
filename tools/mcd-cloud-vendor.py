#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Mobile Claw Deck (MCD), a fork of BCD (https://github.com/thebcd69/bcd-games) by ausfowler.
# Added 2026-11-02. Includes work from BCD by thebcd69.
"""Brings OpenNOW's iOS GeForce NOW engine into app/MCDCloud (MCD's Cloud package).

    python3 tools/mcd-cloud-vendor.py /path/to/opennow-checkout

The checkout must be OpenCloudGaming/OpenNOW at a commit of its iOS branch (kief5555/ios). The
script is run again, unchanged, for each OpenNOW update; every step either succeeds exactly or
stops with an error, and nothing is left half-written (all of it lands in a staging folder first).

What it does:
  1. Copies every .swift file under ios/OpenNOWiOS/OpenNOWiOS into
     app/MCDCloud/Sources/MCDCloud/OpenNOW, keeping OpenNOW's folders. Nothing else of the app is
     copied (its Info.plist, asset catalog, string catalog and privacy manifest belong to an app,
     not a package).
  2. Applies MCD's patches (PATCHES below). Each one names the exact text it replaces and fails
     if that text is not there exactly once, so an OpenNOW change can never be patched by guess.
  3. Unpacks OpenNOW's vendored OpenSSL and usrsctp after checking the archive's SHA-256 against
     OpenNOW's own pin (BuildScripts/prepare-native-libraries.py), and copies WebRTC; each keeps
     only its iPhone (ios-arm64) library, the only one MCD builds.
  4. Renames OpenSSL's copies of 15 CRYPTOGAMS assembly routines (OPENSSL_PREFIXED). MCD already
     links GnuTLS (app/Madeira/libgnutls.a), whose aes-aarch64.o, ghash-aarch64.o and
     sha*-armv8.o define the same global names: linked together, AES is a duplicate-symbol link
     error, and for the other four the linker would silently bind OpenSSL's calls to GnuTLS's
     copies. Renamed (definitions and every reference, in every member of the archive),
     OpenSSL only ever calls its own code. The script then proves it: no old name is left
     defined or referenced in OpenSSL, every new name is defined once, and OpenSSL, usrsctp and
     MCD's four static libraries share no global name at all.
  5. Writes app/MCDCloud/UPSTREAM.md (the commit, the patches and the renamed routines) and the
     licence texts the app carries (app/Madeira/legal/LICENSES: MIT-OpenNOW, Apache-2.0-OpenSSL,
     BSD-3-usrsctp, BSD-3-WebRTC; Settings › About lists them).

Needs: git, llvm-ar and llvm-objcopy, llvm-nm (LLVM 15 or later; any OS).
"""
import hashlib
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "app" / "MCDCloud"
SOURCES = PACKAGE / "Sources" / "MCDCloud" / "OpenNOW"
FRAMEWORKS = PACKAGE / "Frameworks"
LICENSES = PACKAGE / "Licenses"
LEGAL = ROOT / "app" / "Madeira" / "legal" / "LICENSES"
BCD_STATIC = [ROOT / "app" / "Madeira" / name for name in ("libgnutls.a", "libnettle.a", "libhogweed.a", "libgmp.a")]

IOS = "ios/OpenNOWiOS"
APP = IOS + "/OpenNOWiOS"
NATIVE_ZIP = IOS + "/Frameworks/OpenNOW-iOS-128-native-libraries.zip"
NATIVE_SHA256 = "700e218ace883213de500707095ff322d8ec179235b231ceb61d0007a353ea56"
DEVICE = "ios-arm64"

# MCD's changes to OpenNOW's files: (file under OpenNOW/, exact old text, new text, why).
PATCHES = [
    ("OpenNOWiOSApp.swift",
     "@main\nstruct OpenNOWiOSApp: App {",
     "#if OPENNOW_STANDALONE_APP // MCD: OpenNOW's own app entry; MCD is the app, so this is never compiled.\n@main\nstruct OpenNOWiOSApp: App {",
     "MCD is the app: OpenNOW's @main entry point must not be compiled into it."),
    ("OpenNOWiOSApp.swift",
     "                .onOpenURL { url in\n                    store.handleIncomingURL(url)\n                }\n        }\n    }\n}\n",
     "                .onOpenURL { url in\n                    store.handleIncomingURL(url)\n                }\n        }\n    }\n}\n#endif // OPENNOW_STANDALONE_APP\n",
     "Closes the block opened above."),
    ("NativeStreamInput.swift",
     "guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,",
     "guard let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first, // MCD: Documents is the user's folder in Files",
     "OpenNOW writes controller-rumble-status.json for diagnostics; in MCD, Documents is the folder you see in Files, so it goes to Caches."),
    # Phase 3 (streaming). A controller button holds one handler at a time; MCD's own input code
    # holds them outside a stream. OpenNOW says when it is about to take them and when it has let
    # them go (it sets them to nil), so MCD steps aside first and takes them back after.
    ("NativeStreamInput.swift",
     "    func attach() {\n        NotificationCenter.default.addObserver(\n            self,\n            selector: #selector(refreshDevices),\n            name: NSNotification.Name.GCKeyboardDidConnect,",
     "    func attach() {\n        NotificationCenter.default.post(name: MCDCloudInput.willAttach, object: nil) // MCD: MCD's input code steps aside first\n        NotificationCenter.default.addObserver(\n            self,\n            selector: #selector(refreshDevices),\n            name: NSNotification.Name.GCKeyboardDidConnect,",
     "The stream's input says it is about to take the controllers, keyboard and mouse (MCDCloudInput.willAttach), before it sets their handlers."),
    ("NativeStreamInput.swift",
     "        shortcutButtonIDsBySlot.removeAll()\n        lastHapticsAdvertisementAt = -.infinity\n    }\n\n    func sendTouchMouseMove(",
     "        shortcutButtonIDsBySlot.removeAll()\n        lastHapticsAdvertisementAt = -.infinity\n        NotificationCenter.default.post(name: MCDCloudInput.didDetach, object: nil) // MCD: MCD's input code takes them back\n    }\n\n    func sendTouchMouseMove(",
     "The stream's input says it has let them go (MCDCloudInput.didDetach), after it has cleared their handlers."),
    ("NativeStreamInput.swift",
     "        if controllerHUDActive {\n            if button === gamepad.buttonA { onControllerHUDCommand?(.activate); return }\n            if button === gamepad.buttonB { onControllerHUDCommand?(.back); return }\n        }\n        let action = controllerShortcuts.action(for: name)\n",
     "        if controllerHUDActive {\n            if button === gamepad.buttonA { onControllerHUDCommand?(.activate); return }\n            if button === gamepad.buttonB { onControllerHUDCommand?(.back); return }\n        }\n"
     "        // MCD: View + Menu together open and close the stream's controls, as Back + Start opens MCD's own in-game\n"
     "        // menu. Both are kept from the game until released (the one pressed first has already reached it).\n"
     "        if let options = gamepad.buttonOptions,\n"
     "           (button === gamepad.buttonMenu && options.isPressed) || (button === options && gamepad.buttonMenu.isPressed) {\n"
     "            blockedButtons.insert(ObjectIdentifier(gamepad.buttonMenu))\n"
     "            blockedButtons.insert(ObjectIdentifier(options))\n"
     "            setControllerHUDActive(!controllerHUDActive)\n"
     "            onControllerShortcut?(.controls)\n"
     "            return\n"
     "        }\n"
     "        let action = controllerShortcuts.action(for: name)\n",
     "View + Menu together open and close the stream's controls (OpenNOW's own shortcut is a single back button you assign first)."),
    ("StreamLoadingView.swift",
     "private struct QueueAdPlayerCard: View {\n",
     "struct QueueAdPlayerCard: View { // MCD: not private, so MCD's queue screen plays NVIDIA's queue ads with it\n",
     "The queue-ad player is visible to the rest of the module, so MCD's own queue screen can show it (GeForce NOW's free plan requires the ads)."),
]

# OpenSSL's CRYPTOGAMS routines that GnuTLS defines too (proved again on every run, step 4).
OPENSSL_PREFIX = "mcd_ossl_"
OPENSSL_PREFIXED = [
    "_aes_v8_cbc_encrypt", "_aes_v8_ctr32_encrypt_blocks", "_aes_v8_decrypt", "_aes_v8_ecb_encrypt",
    "_aes_v8_encrypt", "_aes_v8_set_decrypt_key", "_aes_v8_set_encrypt_key", "_aes_v8_xts_decrypt",
    "_aes_v8_xts_encrypt", "_gcm_ghash_v8", "_gcm_gmult_v8", "_gcm_init_v8",
    "_sha1_block_data_order", "_sha256_block_data_order", "_sha512_block_data_order",
]


def fail(message):
    sys.exit("mcd-cloud-vendor: " + message)


def run(*args, cwd=None):
    result = subprocess.run(args, cwd=cwd, capture_output=True, text=True)
    if result.returncode != 0:
        fail(f"{' '.join(map(str, args))} failed:\n{result.stderr.strip()}")
    return result.stdout


def tool(name):
    for candidate in (name, name + "-18", name + "-17", name + "-16", name + "-15"):
        if shutil.which(candidate):
            return candidate
    fail(f"{name} not found (install LLVM)")


def defined_globals(nm, archive):
    out = run(nm, "-g", "--defined-only", "--format=just-symbols", str(archive))
    return {line.strip() for line in out.splitlines() if line.strip() and not line.endswith(":")}


def undefined(nm, archive):
    out = run(nm, "-u", "--format=just-symbols", str(archive))
    return {line.strip() for line in out.splitlines() if line.strip() and not line.endswith(":")}


def device_only(xcframework):
    """Keeps only the iPhone library of an .xcframework, its manifest rewritten to match."""
    manifest_path = xcframework / "Info.plist"
    manifest = plistlib.loads(manifest_path.read_bytes())
    libraries = manifest.get("AvailableLibraries", [])
    keep = [lib for lib in libraries if lib.get("LibraryIdentifier") == DEVICE]
    if len(keep) != 1 or keep[0].get("SupportedPlatform") != "ios" or keep[0].get("SupportedPlatformVariant"):
        fail(f"{xcframework.name}: expected exactly one plain ios {DEVICE} library, found {[l.get('LibraryIdentifier') for l in libraries]}")
    for lib in libraries:
        if lib is not keep[0]:
            shutil.rmtree(xcframework / lib["LibraryIdentifier"])
    manifest["AvailableLibraries"] = keep
    manifest_path.write_bytes(plistlib.dumps(manifest))
    leftovers = sorted(p.name for p in xcframework.iterdir() if p.name not in ("Info.plist", DEVICE, "LICENSE"))
    if leftovers:
        fail(f"{xcframework.name}: unexpected entries {leftovers}")
    return xcframework / DEVICE / keep[0]["LibraryPath"]


INCLUDE_OPENSSL = re.compile(r"^(\s*#\s*include\s*)<openssl/", re.MULTILINE)


def framework_includes(headers):
    """OpenSSL's headers include each other as <openssl/x.h>, which only resolves with
    OpenSSL.framework/Headers on the header search path (OpenNOW's Xcode project adds it; a Swift
    package's Swift target has no such setting). Written <OpenSSL/openssl/x.h>, each resolves
    through the framework itself, as `import OpenSSL` already finds the framework."""
    count = 0
    for path in sorted(headers.rglob("*.h")):
        text = path.read_text(encoding="latin-1")
        new, n = INCLUDE_OPENSSL.subn(r"\1<OpenSSL/openssl/", text)
        if n:
            path.write_text(new, encoding="latin-1")
            count += n
    left = [str(p.relative_to(headers)) for p in headers.rglob("*.h")
            if INCLUDE_OPENSSL.search(p.read_text(encoding="latin-1"))]
    if count == 0 or left:
        fail(f"OpenSSL header includes: {count} rewritten, still <openssl/...> in {left[:5]}")
    return count


def prefix_openssl(framework_dir, nm, ar, objcopy):
    binary = framework_dir / "OpenSSL"
    before_defined = defined_globals(nm, binary)
    missing = [s for s in OPENSSL_PREFIXED if s not in before_defined]
    if missing:
        fail(f"OpenSSL no longer defines {missing}: re-check the collision list")
    members = run(ar, "t", str(binary)).split()
    if len(members) != len(set(members)):
        fail("OpenSSL's archive has two members of one name; extracting it would lose one")
    renames = {old: "_" + OPENSSL_PREFIX + old[1:] for old in OPENSSL_PREFIXED}
    with tempfile.TemporaryDirectory() as temp:
        work = Path(temp)
        run(ar, "x", str(binary.resolve()), cwd=work)
        mapping = work / "renames.txt"
        mapping.write_text("".join(f"{old} {new}\n" for old, new in renames.items()))
        for member in members:
            run(objcopy, f"--redefine-syms={mapping}", str(work / member))
        rebuilt = work / "OpenSSL.a"
        run(ar, "rcs", "--format=darwin", str(rebuilt), *members, cwd=work)
        after_members = run(ar, "t", str(rebuilt)).split()
        if after_members != members:
            fail("rebuilt OpenSSL archive lost or reordered members")
        after_defined = defined_globals(nm, rebuilt)
        after_undefined = undefined(nm, rebuilt)
        stale = [s for s in OPENSSL_PREFIXED if s in after_defined or s in after_undefined]
        if stale:
            fail(f"old names still present after the rename: {stale}")
        absent = [new for new in renames.values() if new not in after_defined]
        if absent:
            fail(f"renamed routines not defined: {absent}")
        expected = (before_defined - set(OPENSSL_PREFIXED)) | set(renames.values())
        if after_defined != expected:
            fail("the rename changed more than the 15 routines")
        shutil.copyfile(rebuilt, binary)
    return renames


def main():
    if len(sys.argv) != 2:
        fail("usage: mcd-cloud-vendor.py /path/to/opennow-checkout")
    upstream = Path(sys.argv[1]).resolve()
    if not (upstream / APP / "OpenNOWStore.swift").is_file():
        fail(f"{upstream} is not an OpenNOW checkout with the iOS app ({APP})")
    commit = run("git", "-C", str(upstream), "rev-parse", "HEAD").strip()
    subject = run("git", "-C", str(upstream), "log", "-1", "--format=%cs %s").strip()
    nm, ar, objcopy = tool("llvm-nm"), tool("llvm-ar"), tool("llvm-objcopy")

    with tempfile.TemporaryDirectory() as temp:
        stage = Path(temp) / "MCDCloud"
        sources = stage / "OpenNOW"
        frameworks = stage / "Frameworks"
        licenses = stage / "Licenses"

        # 1. The Swift sources.
        app = upstream / APP
        swift = sorted(p for p in app.rglob("*.swift"))
        names = [p.name for p in swift]
        duplicates = sorted({n for n in names if names.count(n) > 1})
        if duplicates:
            fail(f"two OpenNOW files share a name {duplicates}; one Swift module cannot build both")
        for path in swift:
            target = sources / path.relative_to(app)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, target)

        # 2. MCD's patches.
        for name, old, new, _ in PATCHES:
            path = sources / name
            text = path.read_text()
            if text.count(old) != 1:
                fail(f"patch for {name} no longer applies (its text is there {text.count(old)} times): {old[:60]!r}")
            path.write_text(text.replace(old, new))
        # The only @main left is OpenNOW's own, inside #if OPENNOW_STANDALONE_APP (never defined).
        mains = sorted(str(p.relative_to(sources)) for p in sources.rglob("*.swift")
                       if any(line.strip().startswith("@main") for line in p.read_text().splitlines()))
        if mains != ["OpenNOWiOSApp.swift"]:
            fail(f"@main entry points outside the guarded one: {mains}")

        # 3. The libraries, iPhone only.
        archive = upstream / NATIVE_ZIP
        if hashlib.sha256(archive.read_bytes()).hexdigest() != NATIVE_SHA256:
            fail("OpenNOW's native library archive does not match its pinned SHA-256")
        frameworks.mkdir(parents=True)
        with zipfile.ZipFile(archive) as contents:
            for item in contents.infolist():
                for lib in ("OpenSSL", "usrsctp"):
                    prefix = f"{IOS}/Frameworks/{lib}.xcframework/"
                    if item.filename.startswith(prefix) and not item.is_dir():
                        relative = Path(item.filename[len(f"{IOS}/Frameworks/"):])
                        if ".." in relative.parts:
                            fail("unsafe path in the native library archive")
                        destination = frameworks / relative
                        destination.parent.mkdir(parents=True, exist_ok=True)
                        with contents.open(item) as source, destination.open("wb") as out:
                            shutil.copyfileobj(source, out)
        shutil.copytree(upstream / IOS / "Frameworks" / "WebRTC.xcframework", frameworks / "WebRTC.xcframework", symlinks=True)
        openssl_dir = device_only(frameworks / "OpenSSL.xcframework")
        usrsctp_dir = device_only(frameworks / "usrsctp.xcframework")
        device_only(frameworks / "WebRTC.xcframework")
        rewritten = framework_includes(openssl_dir / "Headers")

        # 4. The rename, then the proof that nothing collides.
        renames = prefix_openssl(openssl_dir, nm, ar, objcopy)
        openssl_syms = defined_globals(nm, openssl_dir / "OpenSSL")
        sctp_syms = defined_globals(nm, usrsctp_dir / "usrsctp")
        bcd_syms = set().union(*(defined_globals(nm, lib) for lib in BCD_STATIC))
        for label, a, b in (("OpenSSL and MCD's static libraries", openssl_syms, bcd_syms),
                            ("usrsctp and MCD's static libraries", sctp_syms, bcd_syms),
                            ("OpenSSL and usrsctp", openssl_syms, sctp_syms)):
            shared = sorted(a & b)
            if shared:
                fail(f"{label} still share {len(shared)} global names: {shared[:10]}")

        # Licences (OpenNOW's MIT notices and the libraries' own).
        licenses.mkdir(parents=True)
        shutil.copyfile(upstream / "LICENSE", licenses / "OpenNOW-LICENSE.txt")
        nvst = app / "NVST"
        shutil.copyfile(nvst / "LICENSE", licenses / "OpenNOW-NVST-LICENSE.txt")
        for path in sorted((nvst / "Licenses").iterdir()):
            shutil.copyfile(path, licenses / path.name)
        shutil.copyfile(frameworks / "WebRTC.xcframework" / "LICENSE", licenses / "WebRTC-BSD-3-Clause.txt")
        shutil.copyfile(nvst / "UPSTREAM.json", licenses / "OpenNOW-NVST-UPSTREAM.json")
        # The copies the app carries (app/Madeira/legal is a bundled folder; Settings › About lists
        # each file): MIT, Apache-2.0 and BSD ask for their notices to travel with the binary.
        def text(name):
            return (licenses / name).read_text(encoding="utf-8")
        bundled = {
            "MIT-OpenNOW.txt": "OpenNOW (https://github.com/OpenCloudGaming/OpenNOW): MCD Cloud's GeForce NOW engine.\n\n"
                               + text("OpenNOW-LICENSE.txt") + "\n--- OpenNOW's iOS NVST receiver ---\n\n"
                               + text("OpenNOW-NVST-LICENSE.txt") + "\n--- OpenNOW-Mac, where the NVST modules come from ---\n\n"
                               + text("OpenNOW-Mac-MIT.txt"),
            "Apache-2.0-OpenSSL.txt": "OpenSSL, as built by OpenNOW (linked statically into MCD Cloud).\n\n" + text("OpenSSL-Apache-2.0.txt"),
            "BSD-3-usrsctp.txt": "usrsctp, as built by OpenNOW (linked statically into MCD Cloud).\n\n" + text("usrsctp-BSD.txt"),
            "BSD-3-WebRTC.txt": "WebRTC.framework, as OpenNOW ships it (embedded in MCD).\n\n" + text("WebRTC-BSD-3-Clause.txt"),
        }

        # 5. The record.
        lines = ["# OpenNOW in MCD",
                 "",
                 "MCD's Cloud engine is OpenNOW's iOS client (https://github.com/OpenCloudGaming/OpenNOW, MIT),",
                 "copied by `tools/mcd-cloud-vendor.py`. Do not edit `Sources/MCDCloud/OpenNOW` or `Frameworks` by",
                 "hand: change the script's patches and run it again.",
                 "",
                 f"- Commit: `{commit}` ({subject})",
                 f"- Swift files: {len(swift)}",
                 "- Libraries: OpenSSL and usrsctp from OpenNOW's pinned archive (SHA-256 "
                 f"`{NATIVE_SHA256}`), WebRTC from OpenNOW's repository; iPhone (ios-arm64) only.",
                 "",
                 "## MCD's patches to OpenNOW's files",
                 ""]
        for name, _, _, why in PATCHES:
            lines.append(f"- `{name}`: {why}")
        lines += ["",
                  "## OpenSSL routines renamed (prefix `" + OPENSSL_PREFIX + "`)",
                  "",
                  "GnuTLS, which MCD already links, defines the same CRYPTOGAMS routines; OpenSSL's copies are",
                  "renamed, definitions and references, so each library only ever calls its own:",
                  ""]
        lines += [f"- `{old}` → `{new}`" for old, new in renames.items()]
        lines += ["",
                  "## OpenSSL headers",
                  "",
                  f"Their {rewritten} `#include <openssl/...>` lines are written `#include <OpenSSL/openssl/...>`, so the",
                  "framework's headers resolve through the framework itself (a Swift package target has no header",
                  "search path setting; OpenNOW's Xcode project adds one)."]
        (stage / "UPSTREAM.md").write_text("\n".join(lines) + "\n")

        # Swap in: only now does anything under app/MCDCloud change.
        PACKAGE.mkdir(parents=True, exist_ok=True)
        for old in (SOURCES, FRAMEWORKS, LICENSES):
            if old.exists():
                shutil.rmtree(old)
        SOURCES.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(sources, SOURCES)
        shutil.copytree(frameworks, FRAMEWORKS, symlinks=True)
        shutil.copytree(licenses, LICENSES)
        shutil.copyfile(stage / "UPSTREAM.md", PACKAGE / "UPSTREAM.md")
        for name, body in bundled.items():
            (LEGAL / name).write_text(body, encoding="utf-8")
    print(f"mcd-cloud-vendor: OpenNOW {commit[:12]}: {len(swift)} Swift files, {len(PATCHES)} patches, "
          f"{len(OPENSSL_PREFIXED)} OpenSSL routines renamed; no shared global names.")


if __name__ == "__main__":
    main()
