# Hybrid sample-buffer clock and HDR tvOS device acceptance

## Status

Partially verified on a physical Apple TV. The 2026-07-17 automated SDR runs prove exact carrier-timebase
binding through pause/rates, forward and backward generation flush, explicit decoder pre-roll rejection
before renderer admission, bidirectional carrier media-selection rebuild, recoverable origin-stall
generation replacement, clean aperture/SAR/quarter-turn rotation/source-cadence rows, fit/fill ownership,
all five host-contract negative cases, E-AC-3 JOC stream-copy startup/seek/selection/stall, and complete
stop/reopen teardown. Native WebVTT also passes graph-bound preflight and AVFoundation
select/deselect/reselect on the carrier. Styled ASS passes Aether overlay select/seek/off/reselect and
AVKit custom-menu installation on the same carrier clock. A deterministic PGS fixture also passes
cue timing, decoded-pixel placement, seek-generation rebuild and select/off/reselect on the physical
device. HDR10 and HLG also have engine/device candidate evidence. Late HDR10+ now has a deterministic
bitstream, complete Apple T.35 attachment, and physical-device same-layer technical pass. All three
remain unadmitted without human panel-mode and visual confirmation.
See
[`hybrid-display-device-evidence-2026-07-17.md`](hybrid-display-device-evidence-2026-07-17.md),
[`hybrid-hdr10plus-device-evidence-2026-07-18.md`](hybrid-hdr10plus-device-evidence-2026-07-18.md), and
[`hybrid-progressive-subtitle-device-evidence-2026-07-18.md`](hybrid-progressive-subtitle-device-evidence-2026-07-18.md).

The complete physical gate remains pending. Source tests prove the bounded no-drop pending queue,
monotonic timing, format-description propagation, HDR10+ per-frame attachment, and absence of
`DisplayImmediately`. The physical late-HDR10+ run also proves first attachment after startup without
changing the Hybrid graph, but the partial runs do not prove the remaining visual/audio, panel-mode,
or Dolby Vision rows. Automated geometry passes, but its final human
visible-orientation/crop confirmation remains part of the visual row.

`AetherHybridPresentationView.verifiedVideoFormats` must remain `[.sdr]` until each additional format row
below has its own fixture and passing physical-device record. There is no Metal or second Hybrid renderer.

## Architecture under test

- `AVPlayerViewController` owns native controls and presents the fixed black H.264 carrier.
- The carrier contains the selected real audio and is the only audio owner.
- One Aether-owned `AVSampleBufferDisplayLayer`, contained by `AetherHybridPresentationView`, presents all
  Hybrid real video.
- The display layer's `controlTimebase` is the exact `AVPlayerItem.timebase` of the carrier. A missing,
  replaced, invalid or drifted binding is terminal.
- Decoded frames become `CMSampleBuffer` values with source PTS/duration, generation, clean aperture,
  pixel aspect ratio, rotation, bit depth, color signaling, static HDR metadata, and per-frame metadata.
- Seek, track switch, stall recovery, stop and reopen flush obsolete samples and reject old generations.
- HDR10+ discovered after startup remains a per-frame attachment on the same display layer. It never
  changes route, player, renderer, track or generation.
- Hybrid does not use `AVSampleBufferRenderSynchronizer`, `AVSampleBufferAudioRenderer`, `MTKView`,
  `DisplayImmediately`, or another presentation clock.

On tvOS, configure the carrier controller while the session is idle, attach `presentationView` beneath
`contentOverlayView`, then call `prepare()`. The carrier stays `.resizeAspect`, automatic AVKit display
criteria are disabled, and real-video fit/fill remains an Aether policy. Missing or mutated host setup is
a typed terminal failure rather than a route switch.

## Fixture contract

Record provenance, redistribution status, byte size and SHA-256 for every fixture. Keep
non-redistributable media under `Fixtures/user/`; never record URLs, headers, cookies, titles or track
names in telemetry evidence.

Required geometry/timing rows:

- 1920x1088 coded frame with 1920x1080 clean aperture;
- non-square pixel aspect ratio;
- 0, 90, 180 and 270 degree display rotation;
- 23.976 or 29.97 fps plus one unusual source rate;
- forward seek, backward seek, pause/resume, rates 0.5, 1.0 and 2.0, stall, stop/reopen.

Required color rows before expanding `verifiedVideoFormats`:

- SDR BT.709;
- 10-bit HDR10 with BT.2020/PQ/matrix and known MDCV/CLLI;
- 10-bit HLG with BT.2020/HLG/matrix;
- HDR10+ with verified ST 2094-40 T.35, including a fixture whose first T.35 payload arrives after startup;
- each promised Dolby Vision profile as a separate row with public Apple API support, profile-specific
  fixture, propagated per-frame metadata and panel-mode evidence.

The first Dolby Vision candidate is Profile 8.4 only: HEVC Main10, HLG/BT.2020 base layer, exact `dvvC`
version/profile/level/flags/compatibility/compression fields, and successful
`kVTDecompressionPropertyKey_PropagatePerFrameHDRDisplayMetadata`. P5, P7, P8.1, a missing record, or a
contradictory record is typed unsupported before provider/session creation; none may be relabelled or
presented as a base-layer-only success.

Required Atmos row:

- a licensed E-AC-3 JOC vector whose bitstream probe reports Atmos/profile 30;
- source and carrier signaling `ec-3` plus `CHANNELS="16/JOC"`;
- JOC stream-copy startup, seek, JOC-to-non-JOC and return selection, recoverable stall, and stop/reopen;
- fixed carrier `BANDWIDTH=2000000` plus privacy-safe observed peak/average telemetry;
- downstream device Atmos indication recorded by a human. The vector and generated fixture stay local
  unless their license explicitly permits redistribution.

Container labels are not evidence. Missing, contradictory, malformed or unpropagated metadata is a
failure. No row may pass through tone mapping, HDR10 relabeling, base-layer-only display or an unverified
Dolby Vision profile.

## Required physical-device run

Record Apple TV model, tvOS build, display model/firmware, Xcode build, Aether commit, host commit, fixture
SHA-256, UTC timestamp, and Match Dynamic Range / Match Frame Rate settings.

1. Start the SDR fixture. Confirm AVKit controls and selected real audio work while
   `AetherHybridPresentationView` alone shows real video.
2. Capture a clock-binding diagnostic showing the layer and current carrier item retain the same timebase
   identity through pause, resume and rates 0.5, 1.0 and 2.0. Video must stop while paused and follow the
   carrier at every rate.
3. Seek forward and backward. Confirm the displayed image is cleared or replaced according to the seek
   contract, no pre-seek generation appears after landing, and telemetry records one new generation.
4. Induce a recoverable carrier stall. Confirm obsolete samples are flushed/rebuilt against the same
   carrier clock without changing route, player, renderer or audio track.
5. Exercise clean aperture, anamorphic ratio, aspect-fit/fill and all rotation rows. The black carrier's
   640x360 geometry must never determine real-video layout.
6. Deliberately replace the carrier item, invalidate its timebase, detach the presentation view, change
   carrier gravity and enable automatic display criteria in diagnostic builds. Each mutation must produce
   the documented typed terminal error without another backend starting.
7. Stop and reopen. Confirm the display layer removes the old image, releases its timebase, the carrier item
   is removed and no previous generation is visible.
8. Run each admitted HDR row. Confirm the intended panel mode, 10-bit path, primaries/transfer/matrix,
   static metadata and applicable per-frame metadata. For late HDR10+, confirm the same layer remains bound
   and the first T.35 attachment does not change route or generation.
9. For every Dolby Vision row, record the exact profile and compare against a documented reference. An
   unlisted profile must resolve to typed unsupported before provider/session creation.
10. For each faithfully convertible text subtitle, confirm the carrier master preserves source
    default/autoselect/forced metadata, AVKit exposes a native legible option, and
    select/deselect/reselect does not stop the carrier clock or replace the renderer. Confirm menu and
    cue rendering visually. Run this row for both graph-bound HLS WebVTT and at least one progressive
    embedded plain-text track. Exercise bitmap/styled subtitle selection separately through the
    Aether overlay and AVKit custom-menu contract.

## Required assertions

- Carrier AVPlayer is the only master clock and only audio owner.
- `displayLayer.controlTimebase` is identity-equal to the current carrier `AVPlayerItem.timebase`.
- PTS and duration remain source-derived and monotonic; `DisplayImmediately` is absent.
- Queue pressure is bounded and terminal; it never drops an accepted frame to conceal overload.
- Old generations cannot enqueue after seek/track switch/stop.
- HDR10+ T.35 is stored in the sample attachment dictionary under
  `kCMSampleAttachmentKey_HDR10PlusPerFrameData`.
- PiP video, AirPlay video and external-display video remain unavailable on Hybrid.
- No failure starts KSPlayer, FFmpegKit, legacy Transmux, MTKView, another AVPlayer or another renderer.

## Evidence record

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
carrierTimebaseIdentityStable: pass | fail
pause: pass | fail
rateHalf: pass | fail
rateNormal: pass | fail
rateDouble: pass | fail
forwardSeekFlush: pass | fail
backwardSeekFlush: pass | fail
stallFlush: pass | fail
trackSwitchFlush: pass | fail
nativeWebVTTSelection: pass | fail | notApplicable
nativeWebVTTVisibleCue: pass | fail | notRecorded
bitmapStyledOverlaySelection: pass | fail | notApplicable
atmosJOCStreamCopy: pass | fail | notApplicable
atmosDownstreamIndicator: pass | fail | notRecorded
carrierDeclaredTransportBudget:
carrierObservedPeakBandwidth:
carrierObservedAverageBandwidth:
lateHDR10PlusSameLayer: pass | fail | notApplicable
observedDisplayMode:
hostContractNegativeCases: pass | fail
stopAndReopen: pass | fail
unexpectedToneMapCount: 0
unexpectedRendererSwitchCount: 0
unexpectedRouteSwitchCount: 0
notes:
```

A missing hash, non-physical runtime, absent panel-mode evidence, unverified bitstream metadata or missing
negative-case archive keeps that row pending.
