# Hybrid HLG physical-device evidence — 2026-07-18

## Decision

The HLG row passes and is admitted for production Hybrid playback. A color-managed BT.2020/HLG
fixture completed on the living-room Apple TV and LG C3 through the one Aether-owned
`AVSampleBufferDisplayLayer`, with the exact carrier timebase still bound at end of stream. The human
observer confirmed that the LG C3 activated its HDR indicator and that the reference color bars and
neutral grayscale looked correct.

`AetherHybridPresentationView.verifiedVideoFormats` is therefore `[.sdr, .hdr10, .hlg]` at candidate
`a9a94696cbbb281a7d2e16c0ab894fe736daeef2`. HDR10+, Dolby Vision, and every unverified Dolby Vision
profile remain typed unsupported before provider/session creation. This record does not admit them.

## Exact candidate and environment

```text
status: pass; HLG production admission
localRunDate: 2026-07-18 Asia/Shanghai
aetherCandidateCommit: a9a94696cbbb281a7d2e16c0ab894fe736daeef2
candidateParent: a353718c693bc2696cf467d241a6bb01ada0d749
branch: feat/syncnext-hybrid-carrier
xcode: 26.4.1 (17E202)
sdk: AppleTVOS 26.4 (23L236)
configuration: Debug, physical arm64 tvOS destination
acceptanceLauncherSHA256: 0cdde41b65228bef2bbe5f8569a47eed5dab57d998aff533deaa92fac5904fc0
acceptanceDebugDylibSHA256: 52874bf2565a1da6b575c76077d51da7d7473c17afe0e57cba9757fbe01f3314
deviceName: 客廳電視
deviceReality: physical
appleTVModel: Apple TV 4K (3rd generation), AppleTV14,1, J255AP
coreDeviceID: 091555FF-9FE8-5A47-B90A-CBDDC737E052
xcodeDestinationUDID: 00008110-000C613A1142801E
tvOS: 26.5 (23L471), Beta
displayModel: LG C3
displayFirmware: not recorded
matchDynamicRangeSetting: enabled in the earlier 2026-07-18 settings row; not re-read immediately before this run
observedDisplayMode: LG C3 activated its HDR indicator for HLG
humanVisualConfirmation: pass; color bars and neutral grayscale reported correct
```

## Color-managed fixture identity

The fixture is generated locally from copyright-clean deterministic code. Its retained 16-bit PPM
stores nonlinear BT.2020 R'G'B' values produced by the ARIB STD-B67 OETF. Color bars use scene-linear
reference level `0.265`; grayscale steps are `0`, `0.005`, `0.018`, `0.05`, `0.18`, `0.265`, `0.5`, and
`1.0`. FFmpeg performs only the BT.2020 non-constant-luminance matrix conversion to video-range 10-bit
YCbCr before x265.

```text
generationCommand: AETHER_ACCEPTANCE_VIDEO_FORMAT=hlg AETHER_ACCEPTANCE_DURATION_SECONDS=60 AETHER_ACCEPTANCE_HLS_SEGMENT_SECONDS=4 bash Scripts/generate-hybrid-acceptance-fixture.sh /tmp/aether-hlg-reference-v2-20260718
fixtureFormat: HEVC Main10 hev1; yuv420p10le; video range; BT.2020 non-constant; ARIB STD-B67 HLG
fixtureDurationSeconds: 60
fixtureSegmentCount: 15 video; 15 in each of two AAC stereo renditions
fixtureByteCount: 15737645
fixtureSHA256SUMSFileSHA256: dfacc4a05bea60eb761d2729fb7928184a8796ed9773d8737397aad6bcac5874
masterPlaylistSHA256: 810820c41d493e1cddfec462b162eb4b62c377d0b0d9360b05e1dea12fdfdb69
videoInitSHA256: cdaed277c3fbf35a5cd7637ffd5ec16339bca0a04cee103760cf7e73f5b44a3d
videoSegment000SHA256: 61514bac037cabec775796800ef8f520fd634acaa0f6b5ee4e446fbfb98068a9
colorReferencePPMSHA256: a7d924d43f811f59116f03ce710e683174eea9420c97381b9f84b073ee3b9763
colorReferenceGeneratorSHA256: c6800dfa8a6065d9f101d78ea31bd7e45a17c96390467628fbba6973efc4e69f
provenanceSHA256: 24662fe76c484616348bb5d654fc286be7732c16e16fea70f8cb948059fb1250
redistribution: generated pattern and sine-wave test media; no third-party audiovisual asset
```

`ffprobe` reads the first decoded frame as Main10 `yuv420p10le`, video range, BT.2020 NCL, and
ARIB STD-B67. Signal statistics report 10-bit Y/U/V; the neutral-pattern averages stay centered near
chroma code 512.

## Device result

The installed binary was built from parent `a353718` plus the single HLG admission line that became
candidate `a9a9469`; the remaining candidate changes are comments and source tests. It therefore
exercises the exact production HLG capability and no additional color admission.

```text
preflightRoute: hybridCarrier
preflightReason: hybridHLSManifestMissingCodecs
decodedVideoFormat: hlg
startupCheckpoint: color-hlg-passed
startupCarrierTimeSeconds: 1.070461499
startupEnqueuedSampleBuffers: 32
generation: 0 throughout
carrierTimebaseBound: true throughout
renderer: rendering throughout
sessionEndedCarrierTimeSeconds: 60.021789238
sessionEndedEnqueuedSampleBuffers: 1440
carrierSegmentsObserved: 15 of 15
carrierBandwidthState: complete
carrierDeclaredTransportBudget: 2000000
carrierObservedPeakBytesPerSecond: 201740
carrierObservedAverageBytesPerSecond: 200202
HDR10PlusAttachedSampleBuffers: 0
routeSwitchCount: 0
rendererSwitchCount: 0
generationChangeCount: 0
terminalFailureCount: 0
```

The human observer reported that HLG activated the LG C3 HDR indicator and that color looked normal.
LG may display the generic `HDR` badge rather than a separate `HLG` label; the source/decoded transfer
was independently verified as ARIB STD-B67.

## Verification and no-fallback audit

- Full `swift test --quiet` — 421 XCTest tests with 2 skipped and no failures; 740 Swift Testing tests in
  130 suites pass.
- Public capability tests admit SDR/HDR10/HLG, reject HDR10+, and require the stale-capability HLS path
  to fail before any origin fetch.
- Physical-destination Debug build, install, startup checkpoint, 60-second end of stream, HDR indicator,
  and human visual row — pass.
- No fallback was added. HDR10+ and Dolby Vision remain typed unsupported; HLG never changed route,
  renderer, player, generation, or clock.
