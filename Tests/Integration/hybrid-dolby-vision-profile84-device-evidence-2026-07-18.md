# Hybrid Dolby Vision Profile 8.4 physical-device evidence — 2026-07-18

## Result

The Dolby Vision Profile 8.4 technical row passes on the physical study-room Apple TV. A generated
HEVC Main10 HLG/BT.2020 HLS fixture carried uncompressed RPU metadata and an exact `dvvC`. Preflight
verified every configuration field and the compatible base layer before provider/session creation.
The hardware decoder repeated those checks, constructed the sample-buffer format description with
`hvcC` plus `dvvC`, and received `noErr` when enabling VideoToolbox per-frame HDR display-metadata
propagation. The existing `AVSampleBufferDisplayLayer` then accepted all 240 decoded frames on
generation 0 while remaining bound to the carrier timebase.

This is a **technical pass**, not production admission. Match Dynamic Range, observed panel mode and
human visual quality were not recorded for this run. The temporary diagnostic admission was removed
immediately after the device build, and
`AetherHybridPresentationView.verifiedVideoFormats` remains `[.sdr]`. Profile 5, Profile 7, Profile
8.1, missing/contradictory configuration and every other unverified Dolby Vision shape remain typed
unsupported before provider/session creation.

## Exact candidate and device

```text
status: technical-pass; panel-mode-and-visual-pending
localRunDate: 2026-07-18 Asia/Shanghai
aetherCandidateCommit: aaa2eb038405798b8497181e3ef45cc4bf6554ce
aetherCandidateParent: 600f715
branch: feat/syncnext-hybrid-carrier
xcode: 26.4.1 (17E202)
sdk: AppleTVOS 26.4
configuration: Debug
acceptanceLauncherSHA256: e36578ec6814162b85a6e6d15226056255c3f4767d4c04f57b9101dc1a2358ed
acceptanceDebugDylibSHA256: db25790a36af7c3e803559d2bcf1f855fec35d7bd31063db819045ba6a907dca
deviceName: 書房 Apple TV
deviceReality: physical
appleTVModel: AppleTV6,2
coreDeviceID: 4F403AE1-B129-5248-BC6E-31DFDD75B422
xcodeDestinationUDID: 771d28ce0d2fe7b0ac1a9fa5d73424b89b54c8a2
tvOS: 26.5 (23L471)
matchDynamicRange: not re-read for this run
matchFrameRate: not re-read for this run
displayModel: not recorded
displayFirmware: not recorded
observedDisplayMode: not recorded
humanVisualConfirmation: pending
```

The Debug product keeps app code in `AetherHybridAcceptance.debug.dylib`, so its SHA-256 is recorded in
addition to the stable launcher executable. The signed diagnostic app was built from the candidate
commit plus exactly two temporary admission edits: `.dolbyVision` was added to
`verifiedVideoFormats`, and `.profile84` was added to `supportedDolbyVisionProfiles`. Both edits were
restored after the run and are absent from the candidate commit. They did not add another player,
route, decoder, renderer, audio owner or clock.

## Public API and profile contract

The admitted candidate follows Apple's Profile 8.4 sample-buffer shape: an HLG-compatible HEVC Main10
base layer, a Dolby Vision configuration atom, and VideoToolbox propagation of per-frame HDR display
metadata. See Apple's [Dolby Vision application note](https://developer.apple.com/av-foundation/Incorporating-HDR-video-with-Dolby-Vision-into-your-apps.pdf),
[HDR media guidance](https://developer.apple.com/news/?id=rwbholxw), and
[`kVTDecompressionPropertyKey_PropagatePerFrameHDRDisplayMetadata`](https://developer.apple.com/documentation/videotoolbox/kvtdecompressionpropertykey_propagateperframehdrdisplaymetadata).

The Aether contract intentionally narrows this to:

```text
configurationVersion: 1.0
profile: 8
level: 1...63
RPU present: true
enhancement layer present: false
base layer present: true
base-layer signal compatibility ID: 4
metadata compression: none
base-layer codec/profile: HEVC Main10
base-layer color: BT.2020 primaries, HLG transfer, BT.2020 non-constant matrix
```

Container labels, an RPU NAL alone, a profile number alone, or a successful base-layer decode do not
satisfy admission.

## Fixture identity

The fixture contains generated `testsrc2` video and generated AAC sine-wave audio only. It is a local,
gitignored release-evidence artifact. Generation is fail-closed: the script refuses a missing/unpinned
`dovi_tool`, an unexpected Dolby Vision record, a mismatched base layer or a first frame whose RPU is
not recognized by FFmpeg.

```text
generator: Scripts/generate-hybrid-acceptance-fixture.sh
generatorFormat: AETHER_ACCEPTANCE_VIDEO_FORMAT=dolbyvision84
ffmpeg: 8.1.1
doviToolVersion: dovi_tool 4b36af9
doviToolSHA256: 1167a5e8973b3173f46f3c330716922d8a17f27bb1605bc33d3d99d0600be255
fixtureDurationSeconds: 10
fixtureFrameCount: 240
fixtureResolution: 1920x1080
fixtureSegments: 3
fixtureAudioRenditions: 2 AAC
fixtureByteCount: 3782948
fixtureSHA256SUMSFileSHA256: a1c5ba96ef48ec1441d5fd24e2478eb0b87abd0dd3b2455e5b1ca590a736f7d9
masterPlaylistSHA256: f755937f916e5236a1e2f6571119de986791d107d7626ec68de4de95c62b8029
videoInitSHA256: be91c50c195e2ef8aed9b31e288cb42d322456daf6eca34a083b93cf394787a8
videoSegment000SHA256: ed7e0ba66c7ce5ce16880c13ceab045532eaba89402c2018d25fbd127a5ee4a7
redistribution: generated test media; no third-party audiovisual asset
```

## Automated physical-device observations

The formal console record is local at
`/tmp/AetherHybridDolbyVision84-20260718-1223-console.log`; it contains 41 lines and has SHA-256
`762fba998080a47263376ccc98432d9e3d1175ce922240b9d82ca4659db48958`. It contains no terminal
failure.

```text
preflightRoute: hybridCarrier
preflightReason: hybridHLSManifestMissingCodecs
preflightProfile84BaseLayerVerified: true
preflightConfiguration: version 1.0; profile 8; level 3; RPU 1; EL 0; BL 1; compatibility 4; compression 0
decoderDVVCAdmission: true
videoToolboxPerFrameMetadataPropagationAccepted: true
videoFormat: dolbyvision
generation: 0
carrierTimebaseBound: true
renderer: rendering
framesEnqueuedAtColorCheckpoint: 74
finalFramesEnqueued: 240
finalPendingFrames: 0
finalCheckpoint: color-dolbyvision-passed
terminalFailureCount: 0
carrierDeclaredTransportBudget: 2000000
carrierObservedPeak: 201738
carrierObservedAverage: 200742
carrierObservedSegments: 3
```

This evidence proves exact source admission, VideoToolbox property acceptance, decoded-frame enqueue,
single-layer rendering and carrier-clock ownership. It does not claim that tvOS entered Dolby Vision
panel mode or that a human verified tone mapping, clipping, color, black-frame absence or RPU-driven
visual differences.

## Verification

- `bash -n Scripts/generate-hybrid-acceptance-fixture.sh` — pass.
- `swift test` — 738 tests in 130 suites, pass.
- AetherEngine Release generic tvOS build — pass.
- Signed diagnostic build/install on the physical study-room Apple TV — pass.
- Profile 8.4 color-path automatic row — pass; 240 frames, one generation, bound carrier timebase,
  one rendering `AVSampleBufferDisplayLayer`, no terminal failure.
- Post-run production-admission diff — clean; `verifiedVideoFormats` is `[.sdr]`.

## Remaining gate

Before adding `.dolbyVision` and `.profile84` to production capabilities, enable Match Dynamic Range,
record the connected display model/firmware and observed Dolby Vision mode, and obtain human visual
confirmation for the real picture. A failure must remain typed unsupported or terminal; it must not
start a base-layer-only presentation, tone-map/relabel the stream, or change route/renderer.

Fallback added: **no**. Explicit failures cover missing, unsupported or contradictory configuration,
P8.4 base-layer mismatch, VideoToolbox metadata-propagation rejection, preflight/decoder configuration
divergence and renderer/session failure.
