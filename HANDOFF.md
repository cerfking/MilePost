# Milepost — project state

A CarPlay **video + audio** app built as a portfolio piece for an Apple
interview: *Car Experience Software Engineer — UI, Wireless Technologies &
Ecosystems*. Verified running on real hardware.

## Toolchain

Xcode 27 beta lives in `~/Downloads`, and `xcode-select` points at 26.6, so every
command needs `DEVELOPER_DIR`:

```bash
export DEVELOPER_DIR=/Users/Cerf/Downloads/Xcode-beta.app/Contents/Developer
```

| | |
| --- | --- |
| Device (iOS 27.0) | `Lu's iPhone13 Pro` — `4E50A481-0E35-5460-B15D-5C66142415B9` |
| Device (iOS 26.6) | `Seb` (iPhone 17 Pro) — `5B8E475C-54DB-5A7A-8F8B-44CD9F86B0CE` |
| Bundle ID | `com.cerf.Milepost` · Team `356XC3P4M8` |
| Profile | `Milepost CarPlay Dev` (manual signing) |
| Entitlement | `com.apple.developer.carplay-video` (granted, Case-ID 21562642) |
| Deployment target | iOS 26.4 |

### Build, test, deploy

```bash
cd ~/Desktop/Swift/Milepost/MilepostKit && swift test          # 21 tests, ~0.001s, no simulator
cd ~/Desktop/Swift/Milepost && xcodebuild -project Milepost.xcodeproj -scheme Milepost \
  -destination 'platform=iOS,id=4E50A481-0E35-5460-B15D-5C66142415B9' -configuration Debug build
```

**Deploy order is mandatory:** `devicectl device uninstall` → `install` → **launch
once** → replug the USB cable. A plain install-over does *not* re-register the app
with CarPlay, and launching after replugging is too late.

Pull on-device diagnostics (the app writes `Documents/carplay-diagnostics.txt`):

```bash
xcrun devicectl device copy from --device <id> --domain-type appDataContainer \
  --domain-identifier com.cerf.Milepost --source Documents/carplay-diagnostics.txt --destination ./d.txt
```

## Architecture

`MilepostKit` (local Swift package, Swift 6, `defaultIsolation(MainActor)`,
strict concurrency clean, no `@unchecked`) + a thin app target.

- `Model/` — `MediaItem`, `Catalog`, `PlaybackState`, `CatalogLoader`. All
  `nonisolated` value types.
- `Playback/PlaybackEngine` — one command path, `perform(_:from:)`. Deliberately
  **not** an actor (`AVPlayer` calls back on main, `@Observable` doesn't work on
  actors, and the real boundary is the process boundary). Observes
  `player.timeControlStatus` so the player is the source of truth.
- `Session/AudioSessionController` — route changes and interruptions.
- `NowPlaying/NowPlayingCenter` — `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter`.
- `Presentation/TemplateSpec` + `TemplateSpecBuilder` — the CarPlay UI as
  `Sendable` values. **This is why 21 tests run without a car.**
- App target: `CarPlaySceneDelegate` (scene lifecycle) and
  `CarPlayTemplateAdapter` (dumb `TemplateSpec` → `CPTemplate` mapping).

## Verified working on device

Tab bar (Videos | Stories) · details header with action buttons · card
thumbnails with NASA posters · `NEW`/`LIVE` `CPImageOverlay` badges · per-item
`CPPlaybackConfiguration` · iOS 27 MiniPlayer · card tap pushes a detail page ·
audio and **video** playback on the car display · correct route-change and
interruption handling.

## Hard-won findings (the interview material)

1. **`UISceneClassName` is required** in the scene manifest. It defaults to
   `UIWindowScene`, and without
   `<string>CPTemplateApplicationScene</string>` iOS silently never registers the
   app as a CarPlay app — no icon, no error, nothing in Settings.
2. **Do not declare `UIWindowSceneSessionRoleApplication`** alongside it in a
   SwiftUI-lifecycle app. SwiftUI owns that scene; declaring it prevents iOS
   vending the CarPlay scene.
3. **Bundled `file://` video cannot be handed to CarPlay** — fails `-11870 /
   -17226` and degrades to audio-only. Video must be an HTTPS stream. Found by
   A/B against an Apple-hosted HLS URL.
4. **`.spokenAudio` blocks video routing.** The session must be `.moviePlayback`
   for video, set *before* playback starts.
5. **A bare `AVPlayer` has no video pipeline.** `allowsExternalPlayback` is
   meaningless without a real video output (`AVPlayerViewController`).
6. **`setRootTemplate` is destructive** — iOS presents its video player on top of
   the template stack, so resetting the root dismisses it. Patch
   `playbackConfiguration` in place; rebuild only when the structure changes.
7. **`preferredPresentation` is a behavioural contract**, not a display hint.
   `.video` makes CarPlay present video itself on selection, so a card that opens
   a detail page must declare `.none` or the two race.
8. **`CPButton.image` is readonly** — a changing Play/Pause glyph requires
   building a new header and assigning `CPListTemplate.listHeader`.
9. **Observe `player.timeControlStatus`.** CarPlay's own video player pauses the
   `AVPlayer` behind your back; state derived only from your own commands goes
   stale.
10. **Simulator builds cannot carry CarPlay entitlements** — Xcode ad-hoc signs
    them and drops entitlements entirely (`<dict></dict>`). Proven, not assumed.
11. **`CPTabBarTemplate` with zero templates is rejected** at runtime and bounces
    to the car home screen, looking identical to a launch failure.
12. **The WWDC session's framing is wrong on availability**: the rich list APIs
    (`CPPlaybackConfiguration`, `CPThumbnailImage`, `CPImageOverlay`,
    `CPListTemplateDetailsHeader`, `CPAssistantCellConfiguration`) are
    **iOS 26.4**; only `allowsMiniPlayer` and
    `CPThumbnailImage.maximumImageSizeForAspectRatio:` are 27.0. Read the headers.
13. **iOS 27.0 beta 24A5408d had a scene regression** — reproduced with Apple's
    own reference sample (github.com/paulw11/CPHelloWorld), which also failed to
    receive a `CPTemplateApplicationScene`. Isolating app code from an OS defect
    with a third-party reference app is the technique worth describing.

## Remaining work

- **README** — architecture diagram, actor-isolation table, the iOS 26.4-vs-27
  availability table, and the findings above. Not yet written.
- **Demo recording** — ~90s, phone and CarPlay side by side.
- Optional: the widget + Live Activity multi-process IPC layer from the original
  plan (`SharedStateStore` / `DarwinBus`), still referenced in a
  `PlaybackEngine` doc comment but never built.
- Cosmetic: an Auto Layout constraint warning from `AVPlayerViewController`
  inside `VideoScreen`.

## Content

3 NASA public-domain videos (streamed via HTTPS, posters bundled) + 4 spoken-word
episodes generated with `say`. Attribution in `CREDITS.md`.
