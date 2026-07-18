# Hybrid Dolby Vision Profile 8.4 physical-device evidence — 2026-07-18

## Decision

Dolby Vision Profile 8.4 passes the complete production-admission row. A color-managed HEVC Main10
HLG/BT.2020 fixture carried uncompressed RPU metadata on every frame and an exact `dvvC`. On the
living-room Apple TV and LG C3, preflight verified the exact Profile 8.4 configuration and compatible
base layer before provider/session creation; VideoToolbox accepted per-frame HDR metadata propagation;
the existing `AVSampleBufferDisplayLayer` rendered all 1440 frames through end of stream while remaining
bound to the carrier timebase. The human observer confirmed that the LG C3 activated its explicit
Dolby Vision indicator and that the reference color bars and neutral grayscale looked correct.

Production candidate `2ac2dd96cc7ffd2cc37a181f87a921ad99599d6c` therefore admits
`.dolbyVision` with exactly `[.profile84]`. Profile 5, Profile 7, Profile 8.1, every other Profile 8
compatibility shape, missing/contradictory configuration, and an unverified base layer remain typed
unsupported before provider/session creation. This decision does not admit HDR10+.

## Living-room production-admission candidate and environment

```text
status: pass; Dolby Vision Profile 8.4 production admission
localRunDate: 2026-07-18 Asia/Shanghai
aetherProductionAdmissionCommit: 2ac2dd96cc7ffd2cc37a181f87a921ad99599d6c
candidateParent: 73f3dfc
branch: feat/syncnext-hybrid-carrier
xcode: 26.4.1 (17E202)
sdk: AppleTVOS 26.4 (23L236)
configuration: Debug, signed physical arm64 tvOS destination
acceptanceLauncherSHA256: da4855ff44c8a9047a422c865691583556315ddcc5ab06cc404cad021c4dcea0
acceptanceDebugDylibSHA256: e3422e410f2a599fb291489d876ebedca87129db82a8994fe73782268f018db2
deviceName: 客廳電視
deviceReality: physical
appleTVModel: Apple TV 4K (3rd generation), AppleTV14,1, J255AP
coreDeviceID: 091555FF-9FE8-5A47-B90A-CBDDC737E052
xcodeDestinationUDID: 00008110-000C613A1142801E
tvOS: 26.5 (23L471), Beta
displayModel: LG C3
displayFirmware: not recorded
matchDynamicRangeSetting: enabled in the earlier 2026-07-18 settings row; not re-read immediately before this run
observedDisplayMode: LG C3 activated its explicit Dolby Vision indicator
humanVisualConfirmation: pass; color bars and neutral grayscale reported correct
```

The Debug product keeps app code in `AetherHybridAcceptance.debug.dylib`, so both executable hashes are
recorded. It was built from parent `73f3dfc` plus exactly the two source lines that became commit
`2ac2dd9`: `.dolbyVision` in `verifiedVideoFormats` and `.profile84` in
`supportedDolbyVisionProfiles`. The remaining commit delta is source tests and cannot change the app
binary. No player, route, decoder, renderer, audio owner or clock was added.

## Color-managed Profile 8.4 fixture identity

The fixture is generated locally from copyright-clean deterministic code. Its retained 16-bit PPM
stores nonlinear BT.2020 R'G'B' values produced by the ARIB STD-B67 OETF. FFmpeg performs only the
BT.2020 non-constant-luminance matrix conversion to video-range 10-bit YCbCr before x265. A pinned
`dovi_tool` then adds uncompressed Profile 8.4 RPU metadata to every frame. Generation fails unless
FFmpeg reads profile 8, compatibility ID 4, RPU and base layer present, enhancement layer absent,
uncompressed metadata, the exact HLG base layer, and an RPU on the first frame.

```text
generationCommand: AETHER_ACCEPTANCE_VIDEO_FORMAT=dolbyvision84 AETHER_ACCEPTANCE_DURATION_SECONDS=60 AETHER_ACCEPTANCE_HLS_SEGMENT_SECONDS=4 AETHER_ACCEPTANCE_DOVI_TOOL=/tmp/dovi_tool-4b36af9/target/release/dovi_tool bash Scripts/generate-hybrid-acceptance-fixture.sh /tmp/aether-dolbyvision84-reference-v2-20260718
fixtureFormat: Dolby Vision Profile 8.4; HEVC Main10 hev1; HLG/BT.2020 non-constant base layer; exact dvvC
fixtureDurationSeconds: 60
fixtureFrameCount: 1440
fixtureSegmentCount: 15 video; 15 in each of two AAC stereo renditions
fixtureByteCount: 16341982
fixtureSHA256SUMSFileSHA256: 6f80cfb62fb97ca7b4a0fc8f35153c8917f0be7572bed92e6383dc23dc2391ad
masterPlaylistSHA256: eeffdc45abbaf9f1c561f9b0f549512f6a2101e2583b70dcab651c6ffa63af10
videoInitSHA256: e5addc4a2a135c51efc1fac93447bbd62b363eac4adba0b400f9d7f1b3f4439d
videoSegment000SHA256: 30ecbe91e2257d945af04bfc0479d6cf563367c51ba395aa41f1acb60400e7b3
colorReferencePPMSHA256: a7d924d43f811f59116f03ce710e683174eea9420c97381b9f84b073ee3b9763
colorReferenceGeneratorSHA256: c6800dfa8a6065d9f101d78ea31bd7e45a17c96390467628fbba6973efc4e69f
provenanceSHA256: 67d02581bbf9915319c2ba277515d6a4540472fdb6b6f5a0d83adc730cac1344
doviToolSourceCommit: 4b36af992a54182f4f8e11198c884d53d5fb5054
doviToolVersion: dovi_tool 2.3.3-2-g4b36af9
doviToolSHA256: 1ae8b0f0e0f9c1e3e43c9a4a2be06eb31c50ed0f5573c6e8eb2aea1943d8bbc1
doviToolBuildRust: isolated Rust 1.95.0 toolchain
redistribution: generated pattern and sine-wave test media; no third-party audiovisual asset
```

## Living-room device result

The formal technical replay is local at
`/tmp/AetherHybridDolbyVision84-LivingRoom-20260718-1754-console.log`; it contains 91 lines and has
SHA-256 `c3c1262308fde46995e8efb4fc664c282d52f37d06f989e1b73aa95ce845e105`. It contains no Aether
session failure or terminal-failure event. The immediately preceding run used the same fixture and app
hashes and supplied the human panel-mode and visual confirmation.

```text
preflightRoute: hybridCarrier
preflightReason: hybridHLSManifestMissingCodecs
preflightProfile84BaseLayerVerified: true
preflightConfiguration: version 1.0; profile 8; level 3; RPU 1; EL 0; BL 1; compatibility 4; compression 0
decoderDVVCAdmission: true
videoToolboxPerFrameMetadataPropagationAccepted: true
decodedVideoFormat: dolbyvision
startupCheckpoint: color-dolbyvision-passed
startupCarrierTimeSeconds: 1.013241467
startupEnqueuedSampleBuffers: 31
generation: 0 throughout
carrierTimebaseBound: true throughout
renderer: rendering throughout
sessionEndedCarrierTimeSeconds: 60.021194873
sessionEndedEnqueuedSampleBuffers: 1440
carrierSegmentsObserved: 15 of 15
carrierBandwidthState: complete
carrierDeclaredTransportBudget: 2000000
carrierObservedPeakBytesPerSecond: 201740
carrierObservedAverageBytesPerSecond: 200202
routeSwitchCount: 0
rendererSwitchCount: 0
generationChangeCount: 0
terminalFailureCount: 0
observedPanelMode: Dolby Vision
humanVisualResult: correct color and grayscale
```

## Earlier study-room technical candidate and device

```text
status: technical-pass; panel-mode-and-visual-pending
localRunDate: 2026-07-18 Asia/Shanghai
aetherFeatureCommit: aaa2eb038405798b8497181e3ef45cc4bf6554ce
aetherCorrectedCandidateCommit: 606efb19c01c17e3d6a516f516ee5e134fce9815
aetherFeatureParent: 600f715
branch: feat/syncnext-hybrid-carrier
xcode: 26.4.1 (17E202)
sdk: AppleTVOS 26.4
configuration: Debug
acceptanceLauncherSHA256: e36578ec6814162b85a6e6d15226056255c3f4767d4c04f57b9101dc1a2358ed
acceptanceDebugDylibSHA256: db25790a36af7c3e803559d2bcf1f855fec35d7bd31063db819045ba6a907dca
correctedCandidateDiagnosticDylibSHA256: 81a36829cc4fd5e0393ad8a7888f4e53df541f930f6007153e0862be1cb98381
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

For this earlier study-room run, the Debug product kept app code in
`AetherHybridAcceptance.debug.dylib`, so its SHA-256 is recorded in
addition to the stable launcher executable. The signed diagnostic app was built from the candidate
commit plus exactly two temporary admission edits: `.dolbyVision` was added to
`verifiedVideoFormats`, and `.profile84` was added to `supportedDolbyVisionProfiles`. Both edits were
restored after the run and are absent from the candidate commit. They did not add another player,
route, decoder, renderer, audio owner or clock.

## Plain-HLG regression correction

The first feature commit exposed a negative cross-format interaction during preparation of the longer
human-observation fixtures: any plain HEVC Main10 HLG/BT.2020 stream satisfied the P8.4-compatible base
layer check even when it carried no Dolby Vision configuration. The probe therefore published a
Dolby Vision base-layer fact with `dolbyVisionConfiguration=none`, and preflight correctly rejected the
contradictory fact pair as `unsupportedDolbyVisionConfigurationMismatch`.

Corrected candidate `606efb19c01c17e3d6a516f516ee5e134fce9815` scopes the compatible-base-layer fact to streams that
also carry an explicit Dolby Vision configuration record. It does not relax the P8.4 checks. New unit
tests require both sides of the boundary: plain HLG has no Dolby Vision fact, while a configured P8.4
stream can retain the positive base-layer fact. A separate route test requires plain HLG `hev1` VOD to
remain `.hybridCarrier`.

The corrected diagnostic app was rebuilt, reinstalled and exercised against independent 60-second HLG
and P8.4 fixtures on the same study-room Apple TV:

```text
HLG fixture SHA256SUMS file: 69ae905c2ee2689fc649f7afb5bae15800156ef57a4cc79571986deb8bf5bd6c
HLG preflight: hybridCarrier; configuration none; P8.4 base-layer fact false
HLG checkpoint: color-hlg-passed; generation 0; timebase bound; renderer rendering; enqueued 74
HLG console SHA256: 0d7e954a42df0c2c3a656355447c1a17f9f917543261456a0352a983835e3cdf

P8.4 fixture SHA256SUMS file: e23b93464f870a820b949b32ed43c7aed527aad8a5e296cb231a39d494ba9c88
P8.4 preflight: hybridCarrier; exact configuration present; P8.4 base-layer fact true
P8.4 decoder: dvvC admitted; VideoToolbox metadata propagation accepted
P8.4 checkpoint: color-dolbyvision-passed; generation 0; timebase bound; renderer rendering; enqueued 74
P8.4 console SHA256: 09cb3d5de348750627ad52081e473dbdf904f4e059d55a0a79b4fb04b965343c
```

Both runs used the same diagnostic admission delta described above. It was again removed after that
build; the corrected production tree was SDR-only at that point. Full `swift test` and the Release
generic tvOS build passed on the corrected candidate. The later living-room row and production commit
`2ac2dd9` supersede this historical admission state for any Syncnext pin or release review.

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

## Earlier 10-second fixture identity

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

## Earlier study-room automated observations

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

This earlier evidence proves exact source admission, VideoToolbox property acceptance, decoded-frame enqueue,
single-layer rendering and carrier-clock ownership. It does not claim that tvOS entered Dolby Vision
panel mode or that a human verified tone mapping, clipping, color, black-frame absence or RPU-driven
visual differences.

A later supplemental run enabled Match Dynamic Range and Match Frame Rate and captured a non-black
Profile 8.4 framebuffer with the carrier timebase bound and the same renderer active. That supplemental
record alone did not prove the external television's Dolby Vision mode or human visual correctness; the
later living-room row above supplies those missing observations. See
[`hybrid-match-content-framebuffer-evidence-2026-07-18.md`](hybrid-match-content-framebuffer-evidence-2026-07-18.md).

## Verification

- `bash -n Scripts/generate-hybrid-acceptance-fixture.sh` — pass.
- Full `swift test --quiet` — 421 XCTest tests with 2 skipped and no failures; 740 Swift Testing tests in
  130 suites pass.
- AetherEngine acceptance app Release generic tvOS build — pass.
- Signed Debug build/install on the physical living-room Apple TV — pass.
- Color-managed Profile 8.4 row — pass; explicit LG C3 Dolby Vision indicator, correct human-observed
  color, 1440 frames, one generation, bound carrier timebase, one rendering
  `AVSampleBufferDisplayLayer`, 15/15 carrier segments and no terminal failure.
- Public capability tests admit the exact Profile 8.4 configuration/base layer and continue to reject
  HDR10+, missing/contradictory Dolby Vision configuration and every other unverified profile.
- Production admission commit — `2ac2dd96cc7ffd2cc37a181f87a921ad99599d6c`.

## Production admission boundary

The Profile 8.4 device and human gate is closed. No other Dolby Vision profile or compatibility shape is
implied by `.dolbyVision`; `supportedDolbyVisionProfiles` remains exactly `[.profile84]`. Any failure must
remain typed unsupported or terminal and must not start a base-layer-only presentation, tone-map/relabel
the stream, or change route/renderer.

Fallback added: **no**. Explicit failures cover missing, unsupported or contradictory configuration,
P8.4 base-layer mismatch, VideoToolbox metadata-propagation rejection, preflight/decoder configuration
divergence and renderer/session failure.
