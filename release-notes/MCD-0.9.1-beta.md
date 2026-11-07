**Mobile Claw Deck (MCD) 0.9.1 beta**: Windows games on iPhone, with a console-style interface and cloud play.

MCD is a fork of [BCD](https://github.com/thebcd69/bcd-games) by thebcd69, which is a fork of [Madeira](https://github.com/willfaust/Madeira). It is not the official BCD: it has its own app ID (`com.ausfowler.mcd`), installs beside BCD and never replaces it. Everything that runs the games is BCD's.

This is a beta: early software. Many games run, many do not yet.

## New in 0.9.1

MCD 0.9.1 brings in BCD's latest update (BCD 0.1.634), with MCD's interface on top:

- **More stores:** itch.io in the Library (sign in with an itch.io API key; a Find a game card sits under the itch.io chip), and an experimental EA store that stays off unless you turn it on under Settings › Accounts.
- **Steam Workshop:** a Workshop button in the Library's top row under the Steam chip, once a Steam game is installed.
- **Steam downloads from a PC on your network** (off by default): a download asks a PC signed in to your Steam account first and takes the rest from Steam.
- **GOG:** install scripts, redistributables, owned DLC, updates and repair. **Epic:** cloud saves, off until you turn them on for a game.
- **In the background** (Settings): keep a game or a download running for a while after you leave the app. Off by default.
- **OpenGL games:** a per-game switch under the game's Options.
- Newer Wine, FEX and DXMT, with BCD's game fixes.

In MCD, the new Workshop button and itch.io card are on the controller's Left/Right walk along the Library's top row, and a cloud stream keeps the controller to itself while it plays.

## What MCD adds

- **Claw Deck's interface:** a big cover carousel on Home whose cards flip to Play, Cloud and the game's settings; GAMES and DOWNLOADS on LB and RB; everything else in the Y menu. Made for a controller; holding a direction scrolls. **Carousel size** in the Y menu makes the cards smaller or larger.
- **Cloud (GeForce NOW):** games GeForce NOW has get a Cloud button on their card. Sign in under Settings › Cloud with your own NVIDIA account. The stream fits your screen, or the shape you choose (Settings › Cloud › Stream shape: 16:9, 16:10 or 4:3). View + Menu opens the stream's controls.
- **iPhone Duo support:** the layout follows the folding screen, open or closed, upright or on its side. On the closed screen the Library shows fewer, larger covers, and upright the tabs sit in a floating glass bar.

## Install

1. Download **MCD-0.9.1-beta.ipa** below.
2. Install it with SideStore, AltStore or LiveContainer.
3. Open MCD. Setup walks you through JIT, LocalDevVPN, Steam and the extra runtimes.

You need iOS / iPadOS 18 or later on an A13 chip or newer, and JIT for Windows games (StikDebug, or the built-in helper on iOS 26 with A15 / M2 and newer). Cloud needs no JIT. Full requirements: the [README](https://github.com/ausfowler/bcd-games#what-you-need).

## Good to know

- MCD keeps its own games, sign-ins and settings: nothing is shared with a BCD install, so set things up once in MCD.
- **Cloud is unofficial.** It uses [OpenNOW](https://github.com/OpenCloudGaming/OpenNOW), an open-source GeForce NOW client. Neither MCD nor OpenNOW is made or endorsed by NVIDIA, and NVIDIA could change or block third-party access at any time. Use it at your own risk and under NVIDIA's terms for your account.
- After LocalDevVPN connects, it may not switch back to MCD by itself: switch back by hand if so.
- Problems: open an [issue here](https://github.com/ausfowler/bcd-games/issues), with the log from Settings › Logs for a crash. Please do not report MCD's problems to BCD.

## Source

**MCD-0.9.1-beta-source.tar.xz** below is the complete source of this release: this repository and all its submodules (Wine, FEX, DXMT, BCD Dock) at this release's pins. MCD is free software under the GNU General Public License, version 3, with the additional terms in LICENSE-BCD.md; third-party licences are in THIRD-PARTY-NOTICES.md and in the app under Settings › About. There is no warranty.

Includes work from BCD by thebcd69 (https://github.com/thebcd69/bcd-games).
