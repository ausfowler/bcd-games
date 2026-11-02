// SPDX-License-Identifier: GPL-3.0-only
// Mobile Claw Deck (MCD), a fork of BCD (https://github.com/thebcd69/bcd-games) by ausfowler.
// Added 2026-11-02. Includes work from BCD by thebcd69.
//
// Phase 4 of the build plan: the stream's mode for the screen a session starts on. OpenNOW's "Auto"
// asks for 1280x720 on any iPhone (StreamSettingsResolver.automaticResolution); MCD asks for the
// GeForce NOW mode that fits the screen in use instead:
//
//   1. the screen's shape: GeForce NOW's aspect (StreamSettingsResolver.aspectRatioOptions) nearest the
//      window's, in landscape (the stream is always landscape), compared as ratios, so 4:3 vs 16:10 is
//      judged the same way from either side;
//   2. its size: the largest of that aspect's modes the plan allows (resolutionChoices) that is not
//      larger than the screen's own pixels in either direction; when none is, the smallest of them;
//   3. its frame rate: 120 when the screen can show it and the plan allows it (OpenNOW allows 120 on
//      Ultimate only), else 60.
//
// Settings › Cloud › Stream shape (phase 4b) can fix the shape instead of step 1: 16:9, 16:10 or 4:3 (Austin found
// 4:3 on the open Duo put bars at the sides; he likes 16:10). Steps 2 and 3 are the same for every shape.
//
// GeForce NOW keeps one mode for a whole session: folding or unfolding afterwards refits the picture,
// nothing restarts (Austin's choice, option A). Pure: tests/host/check-mcd-cloud.py runs the same rule.

import CoreGraphics
import Foundation

struct MCDStreamFit: Equatable {
    let aspectRatio: String
    let resolution: String
    let fps: Int

    /// Settings › Cloud's choice, in UserDefaults (the app's MCDCloudShape writes the same key): "16:9", "16:10" or
    /// "4:3"; anything else (unset, "auto") fits the screen.
    static let shapeKey = "mcd.cloud.shape"

    /// The shape Settings fixed, when it is one of GeForce NOW's; nil fits the screen.
    static func fixedShape(_ stored: String?) -> String? {
        guard let stored, stored != "auto", StreamSettingsResolver.aspectRatioOptions.contains(stored) else { return nil }
        return stored
    }

    static func choose(pixels: CGSize, plan: StreamSettingsResolver.StreamResolutionPlan, maxFPS: Int,
                       shape: String? = nil) -> MCDStreamFit {
        let width = max(pixels.width, pixels.height), height = min(pixels.width, pixels.height)
        let fps = (plan >= .ultimate && maxFPS >= 120) ? 120 : 60
        guard width > 0, height > 0 else { return MCDStreamFit(aspectRatio: fixedShape(shape) ?? "16:9", resolution: "1920x1080", fps: fps) }
        let screen = width / height
        func ratio(_ aspect: String) -> CGFloat {
            let parts = aspect.split(separator: ":").compactMap { Double($0) }
            return parts.count == 2 && parts[1] > 0 ? CGFloat(parts[0] / parts[1]) : 16.0 / 9.0
        }
        let aspect = fixedShape(shape) ?? StreamSettingsResolver.aspectRatioOptions.min {
            abs(log(Double(ratio($0) / screen))) < abs(log(Double(ratio($1) / screen)))
        } ?? "16:9"
        let allowed = StreamSettingsResolver.choices(forAspectRatio: aspect).filter { $0.requiredPlan <= plan }
        func size(_ choice: StreamSettingsResolver.StreamResolutionChoice) -> CGSize { StreamSettingsResolver.pixelSize(choice.value) }
        let fitting = allowed.filter { size($0).width <= width && size($0).height <= height }
        let pick = fitting.max { size($0).width * size($0).height < size($1).width * size($1).height }
            ?? allowed.min { size($0).width * size($0).height < size($1).width * size($1).height }
        return MCDStreamFit(aspectRatio: aspect, resolution: pick?.value ?? "1920x1080", fps: fps)
    }
}
