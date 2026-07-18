# Hybrid progressive subtitle presentation evidence — 2026-07-18

This record closes the progressive native-text visible-cue row and the PGS bitmap physical-fixture row.
It supplements the broader 2026-07-17 display evidence and does not expand the admitted video-format
matrix.

## Exact scope

```text
progressive native-text AetherEngine: 78b6418
bitmap AetherEngine: 0bbcce4e9d775cdee300451128c8e22450531647
branch: feat/syncnext-hybrid-carrier
device: 書房 Apple TV
CoreDevice ID: 4F403AE1-B129-5248-BC6E-31DFDD75B422
Xcode destination ID: 771d28ce0d2fe7b0ac1a9fa5d73424b89b54c8a2
hardware: AppleTV6,2
tvOS: 26.5 (23L471)
```

## Progressive native-text result

The copyright-clean VP9 + AAC + SubRip fixture remains a native carrier subtitle. AVFoundation owns the
`.legible` option and selection; Aether's same-item presentation-only legible-output bridge receives the
public common-format cue. It does not parse the source subtitle or create another clock.

```text
fixtureSHA256: 2f11beda83039a9515e79c2df96489ce02a298e42bf676379ca59e24d975b279
preflightRoute: hybridCarrier
preflightReason: hybridNonAVPlayerCodec
nativeSelect/deselect/reselect: pass
aetherPresentation: true
carrierTimebaseIdentityStable: pass
rendererStatus: rendering
unexpectedRendererSwitchCount: 0
unexpectedRouteSwitchCount: 0
finalCheckpoint: native-webvtt-selection-passed
```

The study-device XCUITest captured `Aether native subtitle — startup` over the real progressive video:

```text
result: /tmp/AetherHybridSubtitleUI-20260718-1016.xcresult
resultInfoSHA256: b6cc5ca961adc8633e5d45a7b7a109acf29c8495c73626cb85f81a910eaaeb91
screenshotSHA256: 98492ba3c32b448d470dd78dd49df70551443ead11900e7152dfc36d97e097f5
hierarchySHA256: 42f8c224d5f3d15a2c68441c96b4ac482e2a5fe7199271be3fbe413e7e8e3b9d
resolution: 3840x2160
```

## PGS bitmap result

`Scripts/generate-hybrid-bitmap-subtitle-fixture.sh` creates deterministic PGS display sets from local
5x7 pixel glyphs. It fails closed on any FFmpeg diagnostic and probes the exact VP9/AAC/PGS stream,
1920x1080 composition canvas and first subtitle PTS. The generated media and provenance remain gitignored.

```text
fixtureSHA256: 012bc66bae9175e9d87110aa7e348ac775c331b798901ad69c18245e2aa29b58
fixtureByteCount: 6226583
fixtureProvenanceSHA256: dab151fc24e0748edd532a2a921ace92388036f5f7ce682c785619e194e28400
fixtureChecksumFileSHA256: 3ad5c34aaffeadbaad47b747a85ebf1e86b2248912c2137f841abdf2e0262b7b
fixtureFormat: VP9 Profile 0 SDR BT.709; AAC stereo; one English PGS track
firstSubtitlePTS: 1.000000 seconds
preflightRoute: hybridCarrier
preflightReason: hybridNonAVPlayerCodec
overlayTrackKind: bitmap
initialOverlaySelection: off
beforeFirstCueVisibleCount: 0
firstCueVisibleAfterPTS: pass at carrierTime 1.1123 seconds
seekGeneration: 0 -> 1
seekTargetAndLanding: 16.5 seconds
seekPrerollRejectedBeforeRenderer: 9 frames
bitmapPixelsVisibleAfterSeek: pass
explicitOffClearsOverlay: pass
reselectRestoresBitmapPixels: pass
carrierTimebaseIdentityStable: pass
rendererStatus: rendering
unexpectedRendererSwitchCount: 0
unexpectedRouteSwitchCount: 0
finalCheckpoint: bitmap-overlay-selection-passed
```

The exact-commit XCUITest captured the authored third cue `SEEK BITMAP 3` over the real video at carrier
time 18.519 seconds, after the generation-changing seek:

```text
result: /tmp/AetherHybridBitmapUI-20260718-1029.xcresult
resultInfoSHA256: 24e2b265b8407700dfb1dec079a7c55589bf1baba307ca6c0b39b19997b9d3ed
screenshotSHA256: 3f3496f21c2e3054f860668e10372015a37592bef3ccfdb950cc58dcbc1a68c6
hierarchySHA256: 2982df6749fc57e39d417ba91d396498a5467c3c126a220cccaaf43148a14db9
attachmentManifestSHA256: 1430203665fa863a24b57b571ac573d6957f43a3703ec8eb992c55da77b324d7
resolution: 3840x2160
```

## Verification

```text
bash -n Scripts/generate-hybrid-bitmap-subtitle-fixture.sh: pass
fixture generation with empty FFmpeg diagnostic log and exact ffprobe contract: pass
swift test: 734 tests in 130 suites passed
generic tvOS Debug build: pass
generic tvOS Release build: pass; signed arm64 AetherHybridAcceptance.app
study Apple TV bitmap console acceptance: pass
study Apple TV progressive/bitmap XCUITest visible-cue screenshots: pass
```

The later exact `1709459` physical Remote/XCUITest run also opens the public AVKit `Aether Subtitles`
custom menu and verifies styled Off/reselect state while the same generation, carrier timebase and
sample-buffer renderer remain healthy. See
[`hybrid-avkit-media-selection-ui-device-evidence-2026-07-18.md`](hybrid-avkit-media-selection-ui-device-evidence-2026-07-18.md).

Fallback added: **no**. Explicit failures include fixture-contract mismatch, subtitle decoder/renderer
unavailability, carrier-item/timebase drift and terminal Hybrid session failure. A failed overlay track may
turn that track Off under the approved subtitle-local graceful-degradation policy; it cannot start another
route, video renderer, audio owner or clock.
