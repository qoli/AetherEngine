# Hybrid native WebVTT presentation evidence — 2026-07-18

This record closes the Hybrid text-subtitle presentation defect for Aether commit `78b6418` on the
study Apple TV. It supplements the broader 2026-07-17 display evidence; it does not expand the admitted
video-format matrix.

## Exact scope

```text
AetherEngine: 78b6418
branch: feat/syncnext-hybrid-carrier
device: 書房 Apple TV
CoreDevice ID: 4F403AE1-B129-5248-BC6E-31DFDD75B422
Xcode destination ID: 771d28ce0d2fe7b0ac1a9fa5d73424b89b54c8a2
hardware: AppleTV6,2
tvOS: 26.5 (23L471)
fixtureGraphIdentitySHA256: 26ff6fcdbe484cf5974694a5e4cab3637eed15d5cd167cd75ebde7b4ff2a15b3
fixtureDurationSeconds: 32
fixtureSubtitles: one English WebVTT rendition, eight timeline-aligned segments
```

## Root cause and corrected ownership

The carrier WebVTT payload, AVFoundation legible option, selection state, carrier timeline and private
AVKit caption rendering were all healthy. Physical composition evidence bounded the failure to z-order:
AVKit's caption layer is inside the player-content tree, while
`AVPlayerViewController.contentOverlayView` and Aether's opaque real-video
`AVSampleBufferDisplayLayer` are above that tree. The private caption therefore rendered behind the real
video.

The production correction uses only public APIs:

1. The carrier master continues to publish the source-bound WebVTT rendition.
2. AVKit continues to own its native subtitle menu and `AVPlayerItem` media selection.
3. One `AVPlayerItemLegibleOutput`, attached to that same carrier item, suppresses the now-obscured
   player caption rendering and receives AVFoundation's common-format attributed strings.
4. Aether translates the documented CoreMedia text-markup attributes, including Media Accessibility
   styling and cue geometry, and presents the cue above its real-video display layer.
5. Bitmap/styled Aether subtitles and native WebVTT are mutually exclusive. Selecting an Aether overlay
   explicitly deselects the legible group; selecting native WebVTT explicitly clears the Aether
   bitmap/styled selection.

The bridge does not fetch WebVTT, parse WebVTT, create a second clock, schedule cues independently, or
select another subtitle source. It is the primary presentation surface for the carrier item's selected
text samples, not a fallback renderer. Unsupported vertical cue layout is omitted as the already-approved
track-local graceful degradation; it cannot change player, route, video renderer, audio track or clock.

## Automated and physical results

The standalone acceptance row produced:

```text
preflightRoute: hybridCarrier
preflightNativeSubtitleCount: 1
carrierLegibleOptionCount: 1
nativeSelect: pass
nativeDeselect: pass
nativeReselect: pass
aetherPresentation: true
carrierTimebaseIdentityStable: pass
rendererStatus: rendering
unexpectedRendererSwitchCount: 0
unexpectedRouteSwitchCount: 0
finalCheckpoint: native-webvtt-selection-passed
```

The exact-commit XCUITest
`SyncNextGate1AUIAcceptanceTests/testHybridWebVTTCuePresentation` passed on the study Apple TV and
captured `Aether native WebVTT segment 2` above the real HEVC color-bar picture. Local evidence bundle:

```text
/tmp/SyncNextGate1AUIAcceptance-hybrid-webvtt-78b6418.xcresult
screenshot SHA256: 349483d5e2a2b869ccd7cef971721e5d6845327221524a20f8f3dee4f2d9db0a
hierarchy SHA256: 0616b4c1fe1494081777a62f60459c302e8f4e10015c5baf0daea7b6d8fb90dc
```

The result bundle is local release evidence and is not a source dependency.

## Verification

```text
swift test
result: 734 tests in 130 suites passed

swift test --filter 'HybridNativeWebVTTOverlayBridgeTests|AetherHybridPresentationViewTests'
result: 8 tests in 2 suites passed

xcodebuild -configuration Debug -destination generic/platform=tvOS build
result: pass

xcodebuild -configuration Release -destination generic/platform=tvOS build
result: pass; signed arm64 AetherHybridAcceptance.app

study Apple TV AETHER_ACCEPTANCE_SUBTITLE_AUTORUN=1
result: native-webvtt-selection-passed; aetherPresentation=true

study Apple TV XCUITest visible-cue screenshot
result: pass
```

Fallback added: **no**. Explicit failures remain carrier-item rebinding, terminal renderer/session errors,
and track-local subtitle unavailability; none starts another route or renderer.
