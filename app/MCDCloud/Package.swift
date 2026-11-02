// swift-tools-version:5.9
// SPDX-License-Identifier: GPL-3.0-only
// Mobile Claw Deck (MCD), a fork of BCD (https://github.com/thebcd69/bcd-games) by ausfowler.
// Added 2026-11-02. Includes work from BCD by thebcd69.
//
// MCD's Cloud: GeForce NOW through OpenNOW's iOS engine (Sources/MCDCloud/OpenNOW, MIT; see
// UPSTREAM.md and Licenses/), behind MCD's own interface to it (Sources/MCDCloud/MCD).
//
// A package of its own so OpenNOW's ~127 files build as their own Swift module: none of their
// names (OpenNOW has its own ContentView, its own extensions on View, Color, String) can meet
// BCD's. The app sees only what Sources/MCDCloud/MCD makes public.
//
// Tools version 5.9 keeps Swift 5 language mode, which is how OpenNOW builds (SWIFT_VERSION 5.0).

import PackageDescription

let package = Package(
    name: "MCDCloud",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "MCDCloud", targets: ["MCDCloud"]),
    ],
    targets: [
        // iPhone-only copies of OpenNOW's libraries (tools/mcd-cloud-vendor.py): OpenSSL and usrsctp
        // are static and link into the app; WebRTC is a framework Xcode embeds in the app.
        .binaryTarget(name: "OpenSSL", path: "Frameworks/OpenSSL.xcframework"),
        .binaryTarget(name: "usrsctp", path: "Frameworks/usrsctp.xcframework"),
        .binaryTarget(name: "WebRTC", path: "Frameworks/WebRTC.xcframework"),
        .target(
            name: "MCDCloud",
            dependencies: ["OpenSSL", "usrsctp", "WebRTC"],
            path: "Sources/MCDCloud"
        ),
    ]
)
