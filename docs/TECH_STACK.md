# Tech Stack — Woodshed

Authoritative list of everything the app is built on. **Nothing gets added without updating this
file.** All versions/targets are read from `Woodshed.xcodeproj/project.pbxproj` and the vendored
assets.

## Language & tooling

| Item | Value | Notes |
|------|-------|-------|
| Language | **Swift 5.0** | `SWIFT_VERSION = 5.0` |
| UI framework | **SwiftUI** | Multiplatform lifecycle (`@main struct WoodshedApp: App`) |
| Project format | Xcode `objectVersion = 77` | Xcode 16 project; uses **file-system-synchronized groups** (drop files into `Woodshed/` and they're in the target) |
| Build system | Xcode / `xcodebuild` | No SPM, CocoaPods, or Carthage |
| Dependency manager | **None** | Zero third-party Swift packages (`XCRemoteSwiftPackageReference` count = 0) |

## Platform targets

| Platform | Deployment target | `SUPPORTED_PLATFORMS` |
|----------|-------------------|------------------------|
| macOS | **15.7** | `macosx` |
| iOS / iPadOS | **26.2** | `iphoneos`, `iphonesimulator` |
| visionOS | **26.2** | `xros`, `xrsimulator` |

- `SDKROOT = auto` — one multiplatform target across all of the above.
- **Primary tested platform today: macOS.** iPadOS is a first-class target per the PRD but has not
  been exercised in this spike (see Open Questions).
- Bundle identifier: `com.dayne.woodshed.Woodshed`. `MARKETING_VERSION = 1.0`.
- **App Sandbox is DISABLED** (`ENABLE_APP_SANDBOX = NO`). See [DECISIONS.md](DECISIONS.md) ADR-007.

## Apple frameworks in use

| Framework | Used by | Purpose |
|-----------|---------|---------|
| SwiftUI | all views | UI, app lifecycle, state (`@State`, `@StateObject`, `@Published`) |
| Combine | `AudioEnginePlayer`, `MIDIInput`, `NotationBridge` | `ObservableObject` / `@Published` (imported explicitly) |
| WebKit | `NotationWebView` | `WKWebView` hosting the OSMD notation renderer |
| AVFoundation | `AudioEnginePlayer` | `AVAudioEngine`, `AVAudioUnitSampler` (×2), `AVAudioSequencer`, `AVAudioPlayerNode` (metronome), `AVAudioPCMBuffer` |
| CoreMIDI | `MIDIInput` | MIDI input (UMP / `MIDIEventList`) and output (`MIDIPacketList`) — device I/O |
| Foundation | parsers | `XMLParser` (SAX) for MusicXML; hand-rolled binary reader for SMF |

## Third-party / vendored assets

| Asset | Version | Location | Why | License note |
|-------|---------|----------|-----|--------------|
| **OpenSheetMusicDisplay (OSMD)** | **2.0.0** | `Woodshed/Web/opensheetmusicdisplay.min.js` (~1.26 MB, vendored/bundled) | Renders MusicXML to SVG notation inside the WKWebView. Chosen per PRD; Swift owns the data model, OSMD only draws + moves a cursor. Bundles VexFlow + JSZip + glyph fonts, so it renders **fully offline**. | Downloaded from the official jsDelivr release. Verify OSMD's BSD-style licence before distribution. |
| **General MIDI sound bank** | macOS system | `/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls` (loaded at runtime, **not bundled**) | Sampled piano for playback via `AVAudioUnitSampler`. Zero app-size cost for the macOS spike. | System resource; **not available on iPadOS** — a bundled SoundFont/`.sf2` will be required there (see Open Questions). |

## Bundled sample content (test scores)

`Woodshed/Scores/` — paired MuseScore 4.7.3 exports used as fixtures:

- `Fly Me To the Moon.musicxml` + `.mid` (swing, 4/4)
- `chopin-nocturne-op-9-no-2-e-flat-major.musicxml` + `.mid` (rubato, 12/8 with meter changes,
  pickup, ornaments, tuplets)

> Copyright note: "Fly Me to the Moon" is a copyrighted composition; these fixtures live in a
> **private** repo. Do not make the repo public without removing them.

## The web layer (inside `Woodshed/Web/`)

- `index.html` — plain ES5-style JS, no build step, no framework. Loaded into `WKWebView` with the
  OSMD script **inlined** (spliced in place of `<script src=…>`), so there are no `file://`
  sub-resource loads. This is the offline notation surface. Its JS API is the contract in
  [ARCHITECTURE.md](ARCHITECTURE.md#the-wkwebview-js-bridge).

## Pinned constraints

- **No network at runtime.** Everything (notation renderer, fonts, sounds, scores) is local. Do not
  introduce runtime network calls (see PRD non-functional requirements).
- **No new third-party Swift dependency** without an ADR in [DECISIONS.md](DECISIONS.md) and an entry
  here. The PRD anticipates exactly one future addition: **GRDB (SQLite)** for persistence — not yet
  added.

## Open Questions

- **iPad sound source:** the macOS system `.dls` doesn't exist on iPadOS. Which SoundFont/`.sf2` do
  we bundle, and at what size/quality? (PRD §12.2 is still open.)
- **Sandbox:** disabled to unblock WKWebView in the spike. For distribution (esp. Mac App Store, if
  ever) we'd need it back on with correct entitlements. Is App Store distribution in scope? (PRD
  implies direct/Developer-ID distribution only.)
- **Swift version:** project says Swift 5.0, but the SDKs are very new (iOS/visionOS 26.2). Confirm
  whether we intend Swift 5 language mode or should move to Swift 6 with strict concurrency.
- **OSMD 2.0.0** is pinned by the vendored file; there's no update mechanism. Document a refresh
  procedure if we bump it.
