// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
// Modified 2026-10-31 (ausfowler/bcd-games): the Claw Deck look -- ink ground, frosted
// glass, one blue accent, a white focus ring, Segoe-like (SF Pro) type.

import SwiftUI

/// The Claw Deck look (fork, 2026-10-31), replacing BCD's night-violet one (2026-10-18).
/// Values from Claw Deck 3.0 (src/look.rs, ausfowler/rusty-clawdeck): INK 14,16,21; BLUE
/// 26,159,255; MUTED 139,146,154; SOFT 195,200,207; glass rgba(30,34,42,205) with a white
/// hairline; ready green 93,214,109; alert red 255,94,94. The token names stay BCD's, so
/// every screen built on them takes the new look and no screen or setting moves.
enum BCDStyle {
    static let ground = Color(red: 0.039, green: 0.043, blue: 0.059)        // #0A0B0F
    static let groundTop = Color(red: 0.086, green: 0.098, blue: 0.122)     // #16191F
    static let surface = Color(red: 0.118, green: 0.133, blue: 0.165)       // #1E222A (Claw Deck glass)
    static let surfaceRaised = Color(red: 0.149, green: 0.165, blue: 0.200) // #262A33
    static let stroke = Color(red: 0.200, green: 0.216, blue: 0.247)        // #33373F (white 13% on glass)
    static let text = Color(red: 0.957, green: 0.965, blue: 0.973)          // #F4F6F8
    static let textSoft = Color(red: 0.616, green: 0.643, blue: 0.675)      // #9DA4AC (between MUTED and SOFT)
    static let violet = Color(red: 0.102, green: 0.624, blue: 1.0)          // #1A9FFF Claw Deck BLUE (name kept)
    static let fuchsia = Color(red: 0.420, green: 0.776, blue: 1.0)         // #6BC6FF light blue (name kept)
    static let lavender = Color(red: 0.765, green: 0.784, blue: 0.812)      // #C3C8CF Claw Deck SOFT (name kept)
    static let mint = Color(red: 0.365, green: 0.839, blue: 0.427)          // #5DD66D
    static let alert = Color(red: 1.0, green: 0.369, blue: 0.369)           // #FF5E5E

    /// Claw Deck's accent and its controller-glyph colours (look.rs `hint`).
    static let accent = violet
    static let ink = Color(red: 0.055, green: 0.063, blue: 0.082)           // #0E1015 INK
    static let padA = Color(red: 0.184, green: 0.659, blue: 0.310)          // #2FA84F
    static let padB = Color(red: 0.851, green: 0.220, blue: 0.227)          // #D9383A
    static let padX = Color(red: 0.153, green: 0.475, blue: 0.839)          // #2779D6
    static let padY = Color(red: 0.878, green: 0.663, blue: 0.110)          // #E0A91C

    static let glow = LinearGradient(colors: [violet.opacity(0.95), violet.opacity(0.55)], startPoint: .leading, endPoint: .trailing)
    static let backdrop = LinearGradient(colors: [groundTop, ground, ground], startPoint: .top, endPoint: .bottom)

    // Segoe UI on Claw Deck; SF Pro (the default design) is its counterpart on iOS.
    static func title(_ size: CGFloat = 32) -> Font { .system(size: size, weight: .bold, design: .default) }
    static func heading(_ size: CGFloat = 19) -> Font { .system(size: size, weight: .semibold, design: .default) }
    static func body(_ size: CGFloat = 16) -> Font { .system(size: size, weight: .regular, design: .default) }
    static func label(_ size: CGFloat = 15) -> Font { .system(size: size, weight: .semibold, design: .default) }
    /// Claw Deck's spaced capitals ("GAMES", "SETTINGS"): use with .tracking(size * 0.16).
    static func caps(_ size: CGFloat = 15) -> Font { .system(size: size, weight: .bold, design: .default) }
}

/// The full-screen ground behind BCD's own screens, with the logo's glow at the top.
struct BCDBackdrop: View {
    var body: some View {
        // The light is an overlay, so it never sizes the backdrop: a fixed 420-point light
        // in the layout made screens shorter than that (a phone on its side) taller than the
        // screen, pushing their top and bottom bars off it.
        BCDStyle.backdrop
            .overlay(alignment: .top) {
                RadialGradient(colors: [Color.white.opacity(0.07), .clear], center: .top, startRadius: 0, endRadius: 420)
                    .frame(height: 420)
            }
            .clipped()
            .ignoresSafeArea()
    }
}

/// The BCD logo (the app icon's artwork, 256 px: enough for 84 pt at 3x) with the platform's corner and a soft glow.
struct BCDLogoMark: View {
    var size: CGFloat = 76
    var body: some View {
        Image("BCDLogo")
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous))
            .shadow(color: Color.black.opacity(0.5), radius: size * 0.2, y: size * 0.06)
            .accessibilityLabel("BCD")
    }
}

/// The main action: Claw Deck's focused button -- blue glass fill, white 2 pt ring, soft blue glow.
struct BCDPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        configuration.label
            .font(BCDStyle.label(17))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(LinearGradient(colors: [BCDStyle.accent.opacity(0.62), BCDStyle.accent.opacity(0.28)],
                                       startPoint: .leading, endPoint: .trailing), in: shape)
            .overlay(shape.strokeBorder(Color.white, lineWidth: 2))
            .shadow(color: BCDStyle.accent.opacity(configuration.isPressed ? 0.15 : 0.35), radius: 12)
            .opacity(enabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A quiet second choice: lavender text, full width so it is easy to reach.
struct BCDSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(BCDStyle.label(16))
            .foregroundStyle(BCDStyle.lavender.opacity(configuration.isPressed ? 0.6 : 1))
            .frame(maxWidth: .infinity, minHeight: 46)
            .contentShape(Rectangle())
    }
}

/// An outlined alternative to the primary action.
struct BCDOutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(BCDStyle.label(16))
            .foregroundStyle(BCDStyle.text)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(BCDStyle.surface.opacity(configuration.isPressed ? 0.6 : 0.85),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
    }
}

extension View {
    /// A card in Claw Deck's frosted glass (look.rs `glass`): blurred backdrop, a light top sheen,
    /// a white hairline and a soft shadow, radius 16.
    func bcdCard(padding: CGFloat = 16) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .bcdGlass(cornerRadius: 16)
    }

    /// Claw Deck's glass panel for any view.
    func bcdGlass(cornerRadius: CGFloat = 16) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background {
                ZStack {
                    shape.fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
                    shape.fill(BCDStyle.surface.opacity(0.55))
                    shape.fill(LinearGradient(colors: [Color.white.opacity(0.12), Color.white.opacity(0.04)],
                                              startPoint: .top, endPoint: .bottom))
                }
                .shadow(color: .black.opacity(0.37), radius: 15, y: 9)
            }
            .overlay(shape.strokeBorder(Color.white.opacity(0.13), lineWidth: 1))
    }

    /// Claw Deck's focus treatment (look.rs `focus_fill`): blue wash, white 2 pt ring, blue glow.
    func bcdFocusRing(_ on: Bool, cornerRadius: CGFloat = 14) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background {
                if on {
                    shape.fill(LinearGradient(colors: [BCDStyle.accent.opacity(0.32), BCDStyle.accent.opacity(0.10)],
                                              startPoint: .leading, endPoint: .trailing))
                        .shadow(color: BCDStyle.accent.opacity(0.35), radius: 11)
                }
            }
            .overlay { if on { shape.strokeBorder(Color.white, lineWidth: 2) } }
    }
}
