# Hybrid geometry, Metal and display-criteria tvOS device acceptance

## Status

Pending. Source-level decoded geometry, aspect-fit/fill, quarter-turn rotation, real-video frame-rate
propagation and the AVPlayerViewController writer contract exist, but simulator builds and pure layout
tests do not prove physical display output. `AetherMetalPlayerView.verifiedVideoFormats` must remain
`[.sdr]` until the relevant color rows below have physical evidence.

## Purpose

Prove that the fixed 640×360 SDR black carrier never becomes the source of truth for real-video
geometry, refresh rate or dynamic range. AVPlayerViewController remains the native control/audio host;
AetherEngine remains the sole real-video renderer and display-criteria writer.

On tvOS, the host must `try configureCarrierPlayerViewController(_:realVideoGravity:)` while the
session is idle, attach `metalPlayerView` beneath `contentOverlayView`, then call `prepare()`. The
contract fixes carrier `videoGravity` to `.resizeAspect`, sets
`appliesPreferredDisplayCriteriaAutomatically = false`, binds the session AVPlayer, and leaves real-video
aspect-fit/fill to `AetherMetalPlayerView`. Missing or mutated configuration is terminal
`carrierPresentationNotConfigured` / `carrierPresentationContractChanged`; it does not start AVPlayer,
guess display criteria or switch route. Configuration attempted after idle throws
`carrierPresentationConfigurationTooLate` without mutating the controller.

## tvOS public-API boundary

The current Apple TV SDK makes the renderer split an architecture decision, not a shader-only task:

- tvOS 26 exposes `CALayer.preferredDynamicRange` / `contentsHeadroom`; together with
  `CAMetalLayer.colorspace` and HDR-capable Metal pixel formats these can describe direct PQ/HLG output.
  HDR10 and HLG may therefore proceed to a physical-device candidate after the engine has an exact
  10-bit pixel-buffer/color-metadata contract.
- `CAMetalLayer.wantsExtendedDynamicRangeContent`, `CAMetalLayer.EDRMetadata` and `CAEDRMetadata` are
  unavailable on tvOS in the AppleTVOS 26.4 SDK. The layer therefore has no public tvOS per-frame
  HDR10+ T.35 or Dolby Vision RPU metadata input.
- [Apple's Dolby Vision playback guidance](https://developer.apple.com/news/?id=rwbholxw) names
  `AVPlayer`/`AVPlayerLayer` and `AVSampleBufferDisplayLayer`; the lower-level path requires
  10-bit-or-higher sample buffers carrying Dolby Vision per-frame metadata propagated by
  `VTDecompressionSession`.
- [`kCMSampleAttachmentKey_HDR10PlusPerFrameData`](https://developer.apple.com/documentation/coremedia/kcmsampleattachmentkey_hdr10plusperframedata)
  is a `CMSampleBuffer` attachment, not a Metal drawable attachment. Rendering only the HDR10 base
  layer in Metal would silently drop HDR10+ semantics.

Accordingly, `.hdr10Plus` and `.dolbyVision` must remain outside
`AetherMetalPlayerView.verifiedVideoFormats`. The engine must not relabel a base layer as the original
format, silently tone-map, or route-switch. Before either format can be admitted, the administrator must
choose and validate one explicit presentation route: an engine-owned `AVSampleBufferDisplayLayer`, a
compressed-bitstream AVPlayer repackaging route, or continued typed unsupported. This decision does not
affect the fixed 2 Mbps black-carrier policy.

Primary references:

- [Apple: Using color spaces to display HDR content](https://developer.apple.com/documentation/metal/using-color-spaces-to-display-hdr-content)
- [Apple: Incorporating HDR video with Dolby Vision into your apps](https://developer.apple.com/av-foundation/Incorporating-HDR-video-with-Dolby-Vision-into-your-apps.pdf)
- [Apple: HDR10+ per-frame sample attachment](https://developer.apple.com/documentation/coremedia/cmsamplebuffer/sampleattachments-swift.struct/hdr10plusperframedata)

## Fixture contract

Record provenance, redistribution status, byte size and SHA-256 for every fixture. Keep
non-redistributable media under `Fixtures/user/`; never commit URLs, signed queries, cookies, headers,
titles or track names.

The SDR geometry set must include:

- a coded 1920×1088 frame with a 1920×1080 clean aperture;
- an anamorphic source with a non-square sample aspect ratio;
- 0°, 90°, 180° and 270° display-matrix rotation;
- a standard source rate such as 23.976 or 29.97 fps;
- a source whose rate does not snap to an advertised tvOS Match Frame Rate value.

Before expanding `verifiedVideoFormats`, add separate, bitstream-verified fixtures for HDR10, HDR10+
(including per-frame ST 2094-40 payload), HLG and every promised Dolby Vision profile. Container labels
alone do not establish color format. Record mastering/display metadata, codec/sample entry, bit depth,
primaries, transfer, matrix, frame rate and Dolby Vision profile where applicable.

## Required physical-device run

Record Apple TV model, tvOS build, display model/firmware, Xcode build, Aether commit, host-app commit,
fixture SHA-256 and UTC timestamp. Run with Match Dynamic Range and Match Frame Rate enabled, then repeat
the explicitly named control rows with them disabled.

1. Configure AVPlayerViewController through the public Aether method, attach the engine-owned Metal view
   to `contentOverlayView`, and start the SDR geometry fixture. Confirm native AVKit controls and audio
   operate while only the Metal surface shows real video.
2. Exercise aspect-fit and aspect-fill. Confirm clean aperture, anamorphic SAR, letterbox/pillarbox and
   center crop use real-video metadata rather than the carrier canvas.
3. Play all four rotation rows, seek forward/backward and stop/reopen. Confirm orientation and geometry
   remain stable across generations and no stale drawable survives teardown.
4. For a standard real-video rate, confirm the display switches to the requested rate and structured
   diagnostics report that source rate. For the unusual/unknown-rate row, confirm Aether does not invent
   24 fps or issue a criteria write from the carrier.
5. Confirm the host keeps `appliesPreferredDisplayCriteriaAutomatically = false` and the Metal surface
   beneath `contentOverlayView` for the whole session. Deliberately mutate player binding, carrier gravity,
   automatic-criteria ownership and overlay attachment in diagnostic builds; each mutation must produce
   the matching typed terminal failure without playback startup or route change. Also attempt configuration
   after `prepare()` begins and confirm `carrierPresentationConfigurationTooLate` without controller mutation.
6. Stop and dismiss. Confirm Aether resets `preferredDisplayCriteria`, releases the Metal drawable/queue,
   removes the carrier item and leaves no previous generation visible on reopen.
7. For each future HDR/HLG/Dolby Vision row, confirm the panel enters the intended mode, the Metal output
   preserves the declared transfer/primaries/dynamic metadata, and the image matches a documented
   reference. Any silent SDR tone-map, metadata drop or different panel mode is a failure.

## Required assertions

- Carrier geometry remains 640×360, 16:9, SDR BT.709 and never changes with the source.
- Real-video clean aperture, SAR and rotation are present in `DecodedVideoFrame.geometry` and agree with
  the displayed viewport.
- Decoder output is either exact coded size plus clean aperture or exact already-cropped size. Any other
  dimension relationship produces `decodedFrameDimensionsDiverged`; no proportional crop guess occurs.
- Only canonical 0/90/180/270 rotation is accepted. A non-quarter display matrix fails explicitly.
- AVPlayerViewController owns native controls/audio, uses carrier `.resizeAspect`, and cannot write display
  criteria automatically.
- Aether applies criteria only from a snapped real-video frame rate and restores the previous/default mode
  at teardown. Unknown/unusual rate does not become 24 fps.
- PiP video, AirPlay video and external-display video remain unavailable on the Hybrid route.
- No failure changes source, video format, renderer, player, audio track or playback route.
- HDR10, HDR10+, HLG or Dolby Vision cannot enter `verifiedVideoFormats` from simulator, screenshot or
  shader-unit evidence alone.

## Evidence record

Store one sanitized Markdown or JSON record per device/display combination:

```text
status: pass | fail
appleTVModel:
tvOSBuild:
displayModel:
displayFirmware:
xcodeBuild:
aetherCommit:
hostCommit:
fixtureSHA256:
fixtureByteCount:
fixtureFormat: sdr | hdr10 | hdr10Plus | hlg | dolbyVision
fixtureDVProfile:
matchDynamicRangeEnabled: true | false
matchFrameRateEnabled: true | false
reportedRealVideoFrameRate:
observedDisplayMode:
aspectFit: pass | fail
aspectFill: pass | fail
cleanAperture: pass | fail
pixelAspectRatio: pass | fail
rotation0: pass | fail
rotation90: pass | fail
rotation180: pass | fail
rotation270: pass | fail
forwardSeek: pass | fail
backwardSeek: pass | fail
hostContractNegativeCases: pass | fail
displayCriteriaReset: pass | fail
stopAndReopen: pass | fail
unexpectedToneMapCount: 0
unexpectedCriteriaWriterCount: 0
unexpectedRouteSwitchCount: 0
notes:
```

A missing hash, non-physical runtime, absent panel-mode evidence, unverified bitstream metadata or missing
negative-case archive keeps that row pending.
