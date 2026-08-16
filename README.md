# Milepost

A CarPlay **video and audio** app for iOS 26.4+, built against the CarPlay
framework APIs introduced for iOS 27. It runs on real hardware: templates render
on the car display, audio plays through the head unit, and video streams to the
car over AirPlay.

The interesting part is not the app. It is the split between the framework that
decides *what* the car shows and the thin adapter that maps it onto CarPlay — a
split that makes the CarPlay UI unit-testable without a car, a phone, or a
simulator.

```
MilepostKit  ──►  TemplateSpec (Sendable values)  ──►  CarPlayTemplateAdapter  ──►  CPTemplate
   framework            "what the car shows"              app target, dumb          CarPlay
```

## What it does

- **Videos tab** — card thumbnails with poster art, `NEW`/`LIVE` badges, and
  per-item progress. Selecting a card pushes a detail page with a large header,
  summary, and Play / Add to Queue.
- **Stories tab** — spoken-word audio as a plain list.
- **Now Playing** with the iOS 27 MiniPlayer, and the car's hardware controls
  wired to the same command path as the on-screen buttons.
- **Degrades on purpose** — the Videos tab only exists when the car reports
  `supportsVideoPlayback`, and a video item plays as audio when the car
  withdraws video rather than stopping.

## Architecture

`MilepostKit` is a local Swift package compiled in **Swift 6 language mode** with
`defaultIsolation(MainActor)` and `SWIFT_STRICT_CONCURRENCY=complete`. There is
no `@unchecked Sendable` and no `nonisolated(unsafe)` anywhere in the project.

| Layer | Isolation | Why |
| --- | --- | --- |
| `MediaItem`, `Catalog`, `PlaybackState`, `TemplateSpec` | `nonisolated` value types | Pure data and pure rules; usable from any actor, trivially `Sendable` |
| `PlaybackEngine`, `AudioSessionController`, `NowPlayingCenter` | main actor | `AVPlayer` calls back on the main queue and every consumer is a UI surface |
| `CarPlaySceneDelegate`, `CarPlayTemplateAdapter` | main actor | CarPlay's template APIs are main-actor (`CARPLAY_TEMPLATE_UI_ACTOR`) |

**`PlaybackEngine` is deliberately not an `actor`.** Actor isolation would add an
`await` to every read while removing no race: `AVPlayer` already delivers its
observations on the main queue, every consumer reads on the main actor, and
`@Observable` does not work on actor types at all. The engine's observable
properties are also *flattened* rather than exposing a single `PlaybackState`
struct, because `@Observable` tracks dependencies per property — a view drawing
only the title should not invalidate on every tick of `elapsed`.

The engine observes `player.timeControlStatus` and derives its state from it, so
**the player is the source of truth and commands are only requests**. CarPlay's
own video player pauses the `AVPlayer` directly; state derived from your own
command history goes stale the moment anything else drives playback.

### Why `TemplateSpec` exists

CarPlay template objects can only be built and pushed with a live
`CPInterfaceController` attached to a head unit. Building them directly makes
every interesting rule — which tab exists, what progress a card shows, whether an
item offers video, what the Play button should say — observable only by plugging
in a phone and looking at a screen.

Describing the UI as `Sendable` value types moves all of that into something a
test can assert on:

```bash
cd MilepostKit && swift test     # 21 tests, ~0.001s, no simulator
```

The adapter that maps `TemplateSpec` onto `CPTemplate` is deliberately dumb, so
there is very little left in it that can be wrong.

## API availability

Read from the iOS 27.0 SDK headers rather than the release notes. The WWDC
session presents these as iOS 27 features; **most of them are iOS 26.4.**

| API | Available |
| --- | --- |
| `CPPlaybackConfiguration` (presentation, action, elapsed, duration) | iOS 26.4 |
| `CPSessionConfiguration.supportsVideoPlayback` | iOS 26.4 |
| `CPThumbnailImage`, `CPImageOverlay`, `CPSportsOverlay` | iOS 26.4 |
| `CPListTemplateDetailsHeader`, `CPListTemplate.listHeader` | iOS 26.4 |
| `CPListImageRowItemCardElement` | iOS 26.0 (thumbnail init 26.4) |
| `CPNowPlayingTemplate.allowsMiniPlayer` | **iOS 27.0** |
| `CPThumbnailImage.maximumImageSizeForAspectRatio:` | **iOS 27.0** |

Hence a deployment target of **26.4**: the whole browsing UI compiles
unconditionally, and only the genuine 27.0 APIs need availability checks. The
`carplay-video` *entitlement* still requires iOS 27.

## Things that cost a night to learn

Every one of these fails silently — no exception, no console error.

1. **`UISceneClassName` is required.** It defaults to `UIWindowScene`, so without
   `CPTemplateApplicationScene` iOS never registers the app as a CarPlay app at
   all: no icon, and nothing in Settings → General → CarPlay.
2. **Don't declare `UIWindowSceneSessionRoleApplication`** in a SwiftUI-lifecycle
   app. SwiftUI owns that scene; declaring it stops iOS vending the CarPlay one.
3. **Bundled `file://` video cannot be handed to CarPlay.** It fails `-11870 /
   -17226` and silently degrades to audio-only. Video must be an HTTPS stream —
   found by A/B against an Apple-hosted HLS URL while every diagnostic said the
   handoff had succeeded.
4. **`.spokenAudio` blocks video routing.** The session must be `.moviePlayback`,
   set *before* playback starts.
5. **A bare `AVPlayer` has no video pipeline.** `allowsExternalPlayback` is
   meaningless without a real video output for AirPlay to take over.
6. **`setRootTemplate` is destructive.** iOS presents its video player on top of
   your template stack, so resetting the root dismisses the video the instant it
   appears. Patch `playbackConfiguration` in place; rebuild only when the
   structure changes.
7. **`preferredPresentation` is a behavioural contract, not a display hint.**
   `.video` makes CarPlay present video itself on selection, so a card that opens
   a detail page must declare `.none` — otherwise both fire and you get a race.
8. **`CPButton.image` is readonly.** A Play/Pause glyph that changes requires
   building a new header and assigning `CPListTemplate.listHeader`.
9. **`CPTabBarTemplate` with zero templates is rejected** at runtime and bounces
   to the car's home screen — indistinguishable from a failed launch.
10. **Simulator builds cannot carry CarPlay entitlements.** Xcode ad-hoc signs
    them and drops entitlements entirely, so CarPlay development needs a real
    device and a real provisioning profile.

## Limitations

- **Requires a granted CarPlay entitlement.** `com.apple.developer.carplay-video`
  is assigned by Apple on request; the app cannot be built for CarPlay without
  it, and simulator builds cannot stand in.
- **Video needs network.** Streamed by necessity (see #3). Audio stays bundled
  and works offline.
- **iOS 27.0 beta 24A5408d has a CarPlay scene regression** — on that build iOS
  vends no `CPTemplateApplicationScene` at all. Confirmed to be an OS defect
  rather than app code by reproducing it with a third-party reference sample
  ([paulw11/CPHelloWorld](https://github.com/paulw11/CPHelloWorld)) signed with
  the same profile. The same build renders correctly on iOS 26.6.
- The multi-process widget / Live Activity layer is designed but not built.

## Building

```bash
export DEVELOPER_DIR=/path/to/Xcode-beta.app/Contents/Developer

cd MilepostKit && swift test        # framework tests, no simulator needed

xcodebuild -project Milepost.xcodeproj -scheme Milepost \
  -destination 'platform=iOS,id=<device-udid>' -configuration Debug build
```

Signing is manual and needs a provisioning profile carrying a CarPlay
entitlement. When deploying, **uninstall → install → launch once → replug the
cable**: installing over an existing copy does not re-register the app with
CarPlay.

## Credits

Video clips are excerpts from NASA Goddard Space Flight Center productions, which
are in the public domain — trimmed and re-encoded here for size. NASA does not
endorse this project and no NASA insignia are used. See
<https://www.nasa.gov/nasa-brand-center/images-and-media/> for usage guidelines.

| Clip | NASA identifier |
| --- | --- |
| Earth from Orbit | `GSFC_20150420_Orbit_m11858_2014` |
| Airglow and the Milky Way | `GSFC_20180105_GOLD_m12817_Airglow_Milkyway` |
| The Multi-coloured Glow | `GSFC_20181022_ICON_m12902_Airglow` |

Originals: <https://images.nasa.gov>. The four spoken-word episodes were written
for this project and synthesised locally with the macOS `say` command. The app
icon is generated procedurally with Core Graphics.
