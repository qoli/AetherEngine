# Hybrid display physical-device evidence — 2026-07-17

## Decision

This is a passing record for the automated SDR clock, seek, decoder pre-roll admission, bidirectional
carrier media selection, controlled origin-stall recovery, decoded geometry/rotation/cadence,
host-contract negative cases, E-AC-3 JOC carrier preservation, native WebVTT selection, styled ASS
overlay selection/seek, and stop/reopen
sub-matrix. It is not a pass for the complete Hybrid
display device gate. Human visual/AVKit/audio confirmation, display-mode, HDR10+, and Dolby Vision rows
remain pending. At the time of this run, HDR10 and HLG had engine/device candidate evidence but
remained unadmitted without matching panel-mode and human visual confirmation, so
`AetherHybridPresentationView.verifiedVideoFormats` remained `[.sdr]`. The later color-managed LG C3
rows close HDR10 and HLG and supersede only those parts of this record; current admission is
`[.sdr, .hdr10, .hlg]`. See
[`hybrid-hdr10-device-evidence-2026-07-18.md`](hybrid-hdr10-device-evidence-2026-07-18.md).

## Environment and fixture

```text
status: partial; complete gate remains pending
appleTVModel: Apple TV 4K (AppleTV6,2), physical device
tvOSBuild: 26.5 (23L471)
displayModel: not recorded
displayFirmware: not recorded
xcodeBuild: Xcode 26.4.1 (17E202)
aetherRevision: worktree based on f4d7c862e166335747457d45ac34db1fd05828ff
hostRevision: standalone acceptance app in the same worktree
evidenceTimestampUTC: 2026-07-17T02:45:24Z
fixtureGraphIdentitySHA256: cecdf94949e7d80339b51cfef189d0cc65a20a4b5ac4f10ab00cde3c1b140468
fixtureByteCount: 18676748
fixtureFormat: SDR HEVC Main hev1, 1920x1080, 24 fps; two AAC stereo renditions
fixtureDurationSeconds: 60
fixtureSegmentCount: 15 video segments; 15 segments in each audio rendition
fixtureOrigin: locally generated copyright-clean testsrc2 and sine sources
matchDynamicRangeEnabled: not recorded
matchFrameRateEnabled: not recorded
```

The graph identity is the SHA-256 of the generated `SHA256SUMS` file. Its `PROVENANCE.txt` records
FFmpeg 8.1.1, a 2.5 Mbps requested video bitrate, a 3 Mbps maximum, and English/Spanish synthetic AAC
renditions. The fixture itself remains under the gitignored `Fixtures/` tree.

## Gate 1A rebuilt-native-dependency smoke

After the initial device matrix, Aether's native packages were moved to immutable public qoli fork
revisions and rebuilt from their published exact-source locks:

```text
FFmpegBuild: qoli/FFmpegBuild d24262133163dab1a8997e22493176a0db4adea8
swift-libass: qoli/swift-libass 01c5ebb8ee8b36cefcbcabea819a47208d1e1216
fixtureGraphIdentitySHA256: cecdf94949e7d80339b51cfef189d0cc65a20a4b5ac4f10ab00cde3c1b140468
device: 書房 Apple TV, CoreDevice 4F403AE1-B129-5248-BC6E-31DFDD75B422
app: com.qoli.AetherHybridAcceptance, arm64, Apple Development signed
checkpoint: stop-and-reopen-passed
carrierBudget: 2000000
observedCarrierPeakAtCheckpoint: 201738 bytes/second
observedCarrierAverageAtCheckpoint: 200828 bytes/second
unexpectedRendererSwitchCount: 0
unexpectedRouteSwitchCount: 0
```

The exact-pinned worktree passed all 725 Swift Testing tests in 128 suites and a signed generic tvOS
build before installation. The physical-device run then passed startup, pause, 0.5x/1x/2x rate,
forward/backward seek generation rebuilds, bidirectional audio selection, teardown and reopen on the
single sample-buffer renderer. Console attachment was ended with SIGINT only after the final
checkpoint. This is an ABI/playback smoke for the rebuilt dependencies, not legal approval for static
App Store distribution and not a replacement for the pending human HDR-panel/audible-Atmos rows.

An initial launch against the stale local `Fixtures/hybrid-sdr-hev1-hls` directory ended in typed
`hlsUnsupportedSeekableVODResourceGraph`. No provider, playback session, fallback route or renderer was
started. The passing rerun used the exact graph recorded above.

## Automated physical-device result

The formal runs used `.hybridCarrier` with reason `hybridHLSManifestMissingCodecs`, 15 media segments,
two audio renditions, one Aether-owned `AVSampleBufferDisplayLayer`, and no local diagnostic switch.

```text
carrierTimebaseIdentityStable: pass
pause: pass; carrier advanced about 0.002 seconds over the two-second hold
rateHalf: pass; carrierTime 4.417 seconds at checkpoint
rateNormal: pass; carrierTime 7.312 seconds at checkpoint
rateDouble: pass; carrierTime 13.103 seconds at checkpoint
forwardSeekFlush: pass; generation 0 -> 1; landed 23.105 seconds
forwardSeekPrerollRejectedBeforeRenderer: 72 frames
backwardSeekFlush: pass; generation 1 -> 2; landed 13.105 seconds
backwardSeekPrerollRejectedBeforeRenderer: 24 frames
audioTrackSwitchOutbound: pass; generation 2 -> 3
audioTrackSwitchReturn: pass; generation 3 -> 4
audioTrackSwitchPrerollRejectedBeforeRenderer: 24 frames per rebuild
audioTrackSelectionRestored: true
stopAndReopen: pass
stoppedCarrierItemReleased: true
stoppedCarrierTimebaseBound: false
stoppedPendingSampleBuffers: 0
reopenedPresentationViewIsNew: true
reopenedGeneration: 0
reopenedCarrierTime: 2.851 seconds
reopenedCarrierTimebaseBound: true
unexpectedToneMapCount: 0 in the admitted SDR run
unexpectedRendererSwitchCount: 0
unexpectedRouteSwitchCount: 0
typedSessionFailureCount: 0 before the final passing checkpoint
```

The previous queue-overflow reproduction is superseded by the admission fix: decoder pre-roll outside
the seek target window is now rejected before renderer enqueue and counted in diagnostics/telemetry.
Accepted renderer frames are still never dropped to conceal pressure. The console attachment was
manually ended with SIGINT only after `stop-and-reopen-passed`; that operator action is not an engine
failure. An earlier SIGKILL caused by competing use of the same Apple TV is excluded from evidence.

## Geometry, rotation, and source-cadence result

All rows used copyright-clean local HLS graphs and the same physical Apple TV. The renderer diagnostics
record the newest admitted frame's source-derived duration and geometry; they never derive either from
the fixed 640x360 carrier. Every checkpoint retained the same bound carrier timebase and the same
rendering display layer.

```text
cleanAperture fixtureGraphIdentitySHA256: 29e3385db3c74f1b051600b7e931789ab112b95774d24a9adc5b0fdc920c1ed6
cleanAperture fixtureByteCount: 2492095
cleanAperture sourceProbe: coded 1920x1088; displayed 1920x1080; SAR 1:1; 24 fps
cleanAperture decodedIOSurface: 1920x1080; aperture 0,0,1920,1080; rotation 0
cleanAperture checkpoint: geometry-clean_aperture-passed

sar fixtureGraphIdentitySHA256: f1c71c8a8d582a0f208a6b13ad1eda0fcf6ccbdadb9fbcc645ed47ee64f0f464
sar fixtureByteCount: 2488932
sar decodedGeometry: 720x576; aperture 0,0,720,576; SAR 16:15; display aspect 4:3
sar checkpoint: geometry-sar_4_3-passed

rotation90 fixtureGraphIdentitySHA256: e9055097939d587289e7c43171de658506df2fbdc35541a1f49775420c3946ae
rotation90 fixtureByteCount: 2490650
rotation90 decodedGeometry: 1280x720; canonical clockwise rotation 90
rotation90 checkpoint: geometry-rotation_90-passed

rotation180 fixtureGraphIdentitySHA256: c67655942d2fab15970a99a3c07cf26ec742bc1261c5b4a5e205e65aed0c5834
rotation180 fixtureByteCount: 2490653
rotation180 decodedGeometry: 1280x720; canonical clockwise rotation 180
rotation180 checkpoint: geometry-rotation_180-passed

rotation270 fixtureGraphIdentitySHA256: 9910b7ca9012c6b83c6911d3498901120f7fe2878c9fe707f633b2d3494d48e4
rotation270 fixtureByteCount: 2490653
rotation270 decodedGeometry: 1280x720; canonical clockwise rotation 270
rotation270 checkpoint: geometry-rotation_270-passed

filmCadence fixtureGraphIdentitySHA256: 9773db4bc16789a0666aa919bf260d8b7d8203697f0723aef641db1377a6a888
filmCadence fixtureByteCount: 6648864
filmCadence decodedFrameRate: 23.976023976 fps from sample duration
filmCadence checkpoint: geometry-fps_24000_1001-passed

unusualCadence fixtureGraphIdentitySHA256: 0e95b825203a9c58af529c6e53f25de7eb4bd350b5adc34b27c4308b107ec13a
unusualCadence fixtureByteCount: 2486146
unusualCadence decodedFrameRate: 15 fps from sample duration
unusualCadence checkpoint: geometry-fps_15-passed

realVideoAspectFillCarrierAspectFitIsolation: pass
gravityPolicyCheckpoint: geometry-gravity-policy-passed
typedSessionFailureCount: 0 in the accepted runs
```

The clean-aperture source carries an HEVC 1920x1088 coded picture with a 1920x1080 conformance window.
VideoToolbox returns the allowed platform-cropped 1920x1080 IOSurface form, so the propagated clean
aperture is the full decoded surface. The source probe and decoded-surface diagnostics are both retained
rather than misreporting the carrier canvas as coded geometry. Rotation fixture modes are canonical
clockwise; their MP4 display matrices use FFmpeg's opposite counter-clockwise sign.

Switching Aether's real-video policy from aspect-fit to aspect-fill left the AVKit carrier controller at
`.resizeAspect` and kept the carrier timebase bound. Automated geometry contract evidence now passes;
human confirmation of the visible crop/orientation is still part of the final visual row.

## Host-contract negative result

All five mutations ran against the same physical Apple TV and Hybrid route. The first four terminate as
`carrierPresentationContractChanged`; replacing the carrier item terminates as
`presentationFailed(.carrierBindingChanged)`. None started another player, renderer, route, or backend.

```text
carrierControllerPlayerReplaced: pass; carrierPresentationContractChanged
carrierControllerGravityChanged: pass; carrierPresentationContractChanged
automaticDisplayCriteriaEnabledBeforePrepare: pass; carrierPresentationContractChanged
presentationViewDetached: pass; carrierPresentationContractChanged
carrierItemReplaced: pass; presentationFailed(carrierBindingChanged)
unexpectedRendererSwitchCount: 0
unexpectedRouteSwitchCount: 0
```

The automatic-display-criteria test is intentionally a preparation-time conflict. An earlier diagnostic
attempt changed that property during full-screen playback, which tvOS itself rejects with an
`NSInvalidArgumentException`; that invalid injection is excluded. The replacement run enabled the
property before `prepare()` and obtained the expected Aether typed terminal error.

## Controlled origin-stall result

The same multi-segment graph was served through the deterministic fixture server. Both copies of
upstream audio source segment 3 were delayed for nine seconds. Nine seconds stays below the origin
loader's ten-second request timeout while exhausting the carrier's buffered audio; it is therefore a
recoverable transport-stall fixture rather than a terminal origin-timeout fixture.

```text
stallObserved: pass; carrierPlaybackStalled at carrierTime 7.9107 seconds
stallForwardBufferSeconds: 0.0893
stallFlush: pass; generation 0 -> 1
stallPrerollRejectedBeforeRenderer: 91 frames
sameCarrierItem: pass
carrierTimebaseIdentityStable: pass
sameRenderer: pass
sameRoute: pass
resumeRate: 1.0
recoveredTimeControlStatus: playing
recoveredForwardBufferSeconds: 4.0779
recoveryCheckpointCarrierTime: 8.5021 seconds
postRecoveryContinuousPlayback: pass; observed beyond carrierTime 27 seconds
typedSessionFailureCount: 0
finalCheckpoint: controlled-stall-recovery-passed
```

The root cause was not an origin retry policy. A slow alternate-audio local request needed an early
chunked response header, and an already-advertised carrier URI had to remain attached when a stall
retired decoder generation 0 and installed generation 1. The server now preserves that single local
request across replacement production. It does not retry the origin, change route, switch audio, or
start another renderer. Focused socket and pump concurrency tests cover both boundaries.

## E-AC-3 JOC / Atmos carrier result

The JOC row used Dolby's official `Silent-Atmos_6ch_448kbps_ddp_joc.ec3` endpoint test signal from the
[Dolby Digital Plus Online Delivery Kit](https://ott.dolby.com/OnDelKits/DDP/Dolby_Digital_Plus_Online_Delivery_Kit_v1.4.1/Test_Signals/elementary_streams/Elementary_Streams.html).
Dolby's [endpoint testing terms](https://professionalsupport.dolby.com/s/article/Endpoint-Device-Testing-for-Streaming-Services)
limit these signals to testing. The elementary stream, downloaded archive, and generated HLS therefore
remain local and gitignored; they are not redistributed with AetherEngine.

```text
sourceVectorSHA256: 9ffe348a4a666b3f7eec27ad41bad955d4f84e0802ca62ea6dd06eed579b6c45
sourceVectorByteCount: 8908032
sourceProbe: E-AC-3; Dolby Digital Plus + Dolby Atmos; 48 kHz; 6 channels; 448000 bps
fixtureGraphIdentitySHA256: 5c2880748e03d2d59b621be4f69bc11f08c31331903e79b1d63ed30bc606dcf2
fixtureByteCount: 10978561
fixtureDurationSeconds: 32
fixtureSegmentCount: 8 video; 8 JOC; 8 AAC
sourceMasterJOCSignal: CHANNELS="16/JOC"
preflightRoute: hybridCarrier
sessionCreateWithStrictAudioContract: pass
defaultSelectedRendition: E-AC-3 JOC
audioTrackSwitchOutbound: pass; JOC -> AAC; generation 2 -> 3
audioTrackSwitchReturn: pass; AAC -> JOC; generation 3 -> 4
forwardSeek: pass
backwardSeek: pass
stopAndReopen: pass
carrierDeclaredTransportBudget: 2000000 bps
carrierObservedPeakBandwidth: 454176 bps
carrierObservedAverageBandwidth: 454176 bps
carrierObservedSegmentCount: 8
carrierBandwidthObservationState: complete
stallObserved: pass; carrierPlaybackStalled at 7.9108 seconds
stallGeneration: 0 -> 1
stallRecoveryCheckpoint: pass at 8.5113 seconds
sameCarrierItemTimebaseRendererRouteAfterStall: pass
typedSessionFailureCount: 0 in accepted runs
```

The local fixture generator first requires FFmpeg to identify the user-supplied vector as E-AC-3
Atmos, packages that rendition with `-c:a:0 copy`, and adds an AAC alternate. Dolby's HLS guidance uses
`ec-3` plus a `CHANNELS` value ending in `/JOC`; the fixture therefore corrects FFmpeg's generic
six-channel declaration to `16/JOC` before hashing. Aether's strict source contract initially rejected
the uncorrected `CHANNELS="6"` graph as `audioContractChanged`. No validation was relaxed: the accepted
run proves the manifest and probed bitstream agree.

Inside Aether, `16/JOC` is produced only by the admitted E-AC-3 profile-30 stream-copy path. A bridge or
transcode would produce another codec/channel descriptor and would fail the same strict contract before
carrier startup. The passing session creation, bidirectional selection rebuild, seek, and stall rows
therefore establish JOC stream-copy preservation through the actual carrier provider. Downstream AVR or
television Atmos-indicator confirmation remains a separate human row.

## Native WebVTT carrier result

The source graph is a copyright-clean local fixture with one selected HLS subtitle group. Aether
preflight binds the subtitle playlist and first WebVTT segment without exposing its URL, republishes
the track as a native carrier rendition, and keeps invalid subtitle tracks track-local rather than
changing playback route. The source's default/autoselect/forced fields now cross the provider boundary;
the local HLS master no longer contains the retired assumption that native subtitles exist only for
PiP while a fullscreen overlay owns all text.

```text
fixtureGraphIdentitySHA256: 26ff6fcdbe484cf5974694a5e4cab3637eed15d5cd167cd75ebde7b4ff2a15b3
fixtureByteCount: 9962183
fixtureDurationSeconds: 32
fixtureSegmentCount: 8 video; 8 in each AAC rendition; 8 WebVTT
fixtureOrigin: locally generated testsrc2, sine, and deterministic cue text
sourceSubtitleSignal: DEFAULT=NO; AUTOSELECT=YES; FORCED=NO
preflightRoute: hybridCarrier
preflightNativeSubtitleCount: 1
preflightUnavailableSubtitleCount: 0
carrierLegibleOptionCount: 1
carrierInitiallySelected: false
nativeSelect: pass
nativeDeselect: pass
nativeReselect: pass
selectionGeneration: 0 -> 3
checkpointCarrierTime: 5.7178 seconds
checkpointCarrierRate: 1.0
carrierTimebaseIdentityStable: pass
rendererStatus: rendering
unexpectedRendererSwitchCount: 0
unexpectedRouteSwitchCount: 0
typedSessionFailureCount: 0
finalCheckpoint: native-webvtt-selection-passed
```

Focused tests also prove that malformed/non-WebVTT source tracks become typed unavailable policies,
and that a subtitle segment failing after startup disables only that rendition while later video and
audio carrier segments continue and the provider remains non-terminal. This is the explicitly approved
subtitle-only graceful degradation; it is not a playback fallback. The original physical automated row
proves AVFoundation exposure and selection. A later exact `78b6418` study-device run also proves public
common-format cue presentation above the real-video layer; see
[`hybrid-native-webvtt-device-evidence-2026-07-18.md`](hybrid-native-webvtt-device-evidence-2026-07-18.md).
The later exact `1709459` physical XCUITest closes AVKit native menu visibility and Remote-driven
Off/On/Off/On selection; panel appearance is captured in the same result. Styled ASS selection is
covered below. Progressive visible-cue and bitmap-overlay rows were subsequently closed by
[`hybrid-progressive-subtitle-device-evidence-2026-07-18.md`](hybrid-progressive-subtitle-device-evidence-2026-07-18.md).

### Progressive plain-text source

A separate copyright-clean VP9 Matroska fixture verifies the non-HLS input boundary. The owning
progressive demux pump admits only explicitly faithful plain-text codecs, decodes their packets into
carrier-timeline cue stores, and republishes them through the same native WebVTT endpoints. ASS/SSA,
bitmap, embedded CEA, and unknown codecs are not converted by this path.

```text
fixtureSHA256: 2f11beda83039a9515e79c2df96489ce02a298e42bf676379ca59e24d975b279
fixtureProvenanceSHA256: 3657e3424731548fde9d52268259356821905d24d2d8efaadfdd5ea0c13bcbd7
fixtureDurationSeconds: 32
fixtureFormat: VP9 Profile 0 SDR BT.709; AAC stereo; one embedded SubRip track
fixtureOrigin: locally generated testsrc2, sine, and deterministic cue text
originRangeContract: pass; strict single-file byte-range server
preflightRoute: hybridCarrier
preflightReason: hybridNonAVPlayerCodec
sourceSubtitleTrackCount: 1
carrierLegibleOptionCount: 1
carrierInitiallySelected: false
nativeSelect: pass
nativeDeselect: pass
nativeReselect: pass
selectionGeneration: 0 -> 3
checkpointCarrierTime: 6.2175 seconds
checkpointCarrierRate: 1.0
carrierTimebaseIdentityStable: pass
rendererStatus: rendering
unexpectedRendererSwitchCount: 0
unexpectedRouteSwitchCount: 0
typedSessionFailureCount: 0
finalCheckpoint: native-webvtt-selection-passed
```

The automated row proves AVFoundation exposure and selection through a real progressive source. The
presentation-only bridge is covered by the later HLS WebVTT visible-cue evidence. A subsequent physical
XCUITest also captured the progressive cue above real video; the exact `1709459` HLS-carrier XCUITest
closes native AVKit menu visibility and Remote selection for the same carrier legible-group contract. See
[`hybrid-progressive-subtitle-device-evidence-2026-07-18.md`](hybrid-progressive-subtitle-device-evidence-2026-07-18.md).

## Styled ASS overlay result

The copyright-clean progressive fixture deliberately uses VP9 so the pure route preflight selects
Hybrid before provider/session creation. Aether probes one embedded ASS track, retains compressed
subtitle packets in the owning progressive demux pump, decodes them with a fresh decoder per
generation, and renders styled pixels through the exact-pinned libass wrapper onto the
`AetherHybridPresentationView` overlay above the one real-video `AVSampleBufferDisplayLayer`.

```text
fixtureSHA256: d016beb1b3c142a2b877591dd359c68b63d4f92cdc13120aaea48427a98ffaf5
fixtureByteCount: 6209307
fixtureDurationSeconds: 32
fixtureFormat: VP9 Profile 0 SDR BT.709; AAC stereo; one embedded ASS track
fixtureOrigin: locally generated testsrc2, sine, and deterministic ASS events
originRangeContract: pass; explicit and suffix requests return 206
originSingleFileIsolation: pass; adjacent checksum request returns 404
preflightRoute: hybridCarrier
preflightReason: hybridNonAVPlayerCodec
overlayTrackCount: 1
overlayTrackKind: styledText
initialOverlaySelection: off
avkitCustomMenuInstalled: pass
styledPixelsVisibleAtStartup: pass
startupCheckpointCarrierTime: 1.1278 seconds
seekGeneration: 0 -> 1
seekTargetAndLanding: 16.5 seconds
seekPrerollRejectedBeforeRenderer: 9 frames
styledPixelsVisibleAfterSeek: pass
explicitOffClearsOverlay: pass
reselectRestoresStyledPixels: pass
carrierTimebaseIdentityStable: pass
rendererStatus: rendering
unexpectedRendererSwitchCount: 0
unexpectedRouteSwitchCount: 0
typedSessionFailureCount: 0
finalCheckpoint: styled-overlay-selection-passed at carrierTime 16.5660 seconds
```

The automated row proves real decoded libass pixels on the presentation canvas, selection lifecycle,
seek-generation rebuild, and AVKit menu installation through the public tvOS API. The later exact
`1709459` Remote XCUITest closes custom-menu visibility and Off/reselect state. The later deterministic
PGS physical-device row closes bitmap decode/composition evidence; see
[`hybrid-progressive-subtitle-device-evidence-2026-07-18.md`](hybrid-progressive-subtitle-device-evidence-2026-07-18.md).

## Source verification

```text
swift test --filter HybridPlaybackSessionTests: pass, 21 tests
swift test: pass; XCTest 407 tests (1 skipped), Swift Testing 725 tests in 128 suites
generic physical-tvOS signed app build: pass
```

The focused test injects 64 pre-target frames followed by the qualifying target frame. All 64 are
reported as rejected before renderer admission, and the render surface receives only the target frame.
Additional focused tests prove early chunked alternate-audio response framing over a real socket and a
pending carrier-audio request transferring from a retired generation to the replacement writer.

## HDR10 and HLG engine/device candidates

These runs establish that decoded Main10 frames reached the same Aether-owned display layer while the
exact carrier timebase advanced on the physical Apple TV. They do not establish the television's active
display mode or visual correctness, so neither format is admitted yet.

```text
HDR10 fixtureGraphIdentitySHA256: fc9b7db7d005d6a78688c2a2f68eb8ccea11eefcaea560f2aaff19634eb0e2de
HDR10 fixtureByteCount: 4394691
HDR10 format: HEVC Main10, yuv420p10le, BT.2020 non-constant/PQ
HDR10 MDCV: R(34000,16000) G(13250,34500) B(7500,3000) WP(15635,16450)
HDR10 luminance: max 1000 nits; min 0.0001 nits
HDR10 CLLI: MaxCLL 1000; MaxFALL 400
HDR10 checkpoint: color-hdr10-passed; carrierTime 2.8340 seconds; enqueued 74
HDR10 sameDisplayLayer: pass
HDR10 carrierTimebaseBound: true
HDR10 typedSessionFailureCount: 0

HLG fixtureGraphIdentitySHA256: 504c8f07785203f333d31fd0ef2fa405204301a2cc47f15ae019362884a17d3a
HLG fixtureByteCount: 4394159
HLG format: HEVC Main10, yuv420p10le, BT.2020 non-constant/ARIB STD-B67
HLG checkpoint: color-hlg-passed; carrierTime 2.8175 seconds; enqueued 74
HLG sameDisplayLayer: pass
HLG carrierTimebaseBound: true
HLG typedSessionFailureCount: 0

panelModeEvidence: pending
humanVisualConfirmation: pending
formatAdmission: pending
```

A supplemental 2026-07-18 run enabled Match Dynamic Range and Match Frame Rate in the physical
device's Settings UI, then captured non-black HDR10, HLG, late-HDR10+ and Dolby Vision Profile 8.4
framebuffers with the carrier timebase bound and the one display layer rendering. This closes the
device-settings and composited-framebuffer sub-rows, but a screenshot cannot prove the external
television's active mode or subjective visual correctness. See
[`hybrid-match-content-framebuffer-evidence-2026-07-18.md`](hybrid-match-content-framebuffer-evidence-2026-07-18.md).

Both copyright-clean fixtures are 12-second, three-segment local graphs with two AAC renditions and are
kept in the gitignored `Fixtures/` tree. Their identities are the SHA-256 values of their generated
`SHA256SUMS` files. During these candidate runs HDR10 and HLG were enabled only in the diagnostic build;
the source contract was restored to `verifiedVideoFormats == [.sdr]` immediately afterward. The later
HDR10 and HLG evidence replaces the SDR-relabeled visual fixtures with color-managed BT.2020/PQ and
BT.2020/HLG references and admits both; it does not alter the historical result of these earlier
diagnostic runs.

## Pending before the complete row can pass

- Match Dynamic Range / Match Frame Rate settings: closed on 2026-07-18. Record the actual display
  model/firmware and external-panel mode for each color row.
- Native AVKit controls, non-black real video and the audio/native-WebVTT/styled custom menus are closed
  by physical XCUITest. Confirm audible selected real audio and the automated SAR/rotation/fit-fill rows
  on the attached panel.
- AVKit UI media selection is closed on 2026-07-18, including JOC → AAC → JOC, native WebVTT
  Off/On/Off/On and styled Off/reselect. Record the downstream Atmos indicator for the JOC row.
- Bitmap subtitle physical-fixture row: closed on 2026-07-18 with decoded-pixel, placement, seek and
  selection evidence.
- HDR10 and HLG panel-mode and human visual confirmation: closed by the 2026-07-18 LG C3
  color-managed rows. Late-metadata HDR10+ and every promised Dolby Vision profile still require their
  own independent panel-mode and human visual evidence.
- Replace the worktree revision above with the committed Aether revision in the final archive.
