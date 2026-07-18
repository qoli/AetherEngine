# Hybrid HDR10 physical-device evidence — 2026-07-18

## Decision

The HDR10 row passes and is admitted for production Hybrid playback. A color-managed BT.2020/PQ
fixture completed on the living-room Apple TV and LG C3 through the one Aether-owned
`AVSampleBufferDisplayLayer`, with the exact carrier timebase still bound at end of stream. After an
explicit player restart, the human observer confirmed both that the LG C3 HDR indicator activated and
that the reference color bars and neutral grayscale looked correct.

`AetherHybridPresentationView.verifiedVideoFormats` is therefore `[.sdr, .hdr10]` at candidate
`057e1e7f0b306c19fce59713eeedb5c8b355295d`. At that exact candidate HLG, HDR10+, Dolby Vision, and
every unverified Dolby Vision profile remained typed unsupported. A later independent LG C3 row admits
HLG, making current admission `[.sdr, .hdr10, .hlg]`; this HDR10 record itself does not admit any other
format.

## Why the first visual run was rejected

The first living-room run used graph identity
`3589c2f4234f786d38b137423d1c56895890f68f28599b6398a87124909c7155`. It correctly carried Main10,
BT.2020/PQ, MDCV, and CLLI signaling and activated HDR output, but its source was FFmpeg `testsrc2`.
The generator converted that SDR test pattern to 10-bit and labelled it as BT.2020/PQ without converting
the pixel values to the declared primaries and transfer function. The human observer reported abnormal
color. That graph is invalid as visual-correctness evidence and is not used for admission.

The same run exposed an independent acceptance-harness timing error: the harness slept for a fixed
three seconds and then required more than one second of carrier progress. The SDR-to-HDR display-mode
switch consumed enough of that interval to produce a false `color-startup` timeout while the renderer
and carrier were healthy. Candidate `057e1e7` replaces the fixed delay with a bounded 15-second
condition poll. A timeout remains a terminal assertion and reports carrier time, rate, time-control,
forward buffer, pending/enqueued samples, timebase binding, and renderer status. It does not retry a
route, switch renderer, or relax any invariant.

## Exact candidate and environment

```text
status: pass; HDR10 production admission
localRunDate: 2026-07-18 Asia/Shanghai
aetherCandidateCommit: 057e1e7f0b306c19fce59713eeedb5c8b355295d
branch: feat/syncnext-hybrid-carrier
xcode: 26.4.1 (17E202)
sdk: AppleTVOS 26.4 (23L236)
configuration: Debug, physical arm64 tvOS destination
acceptanceLauncherSHA256: 76be22b0c168c09074d7ede89ccce1506dc4731551a93dde7fae6bb21625b6d0
acceptanceDebugDylibSHA256: 97a4e46da9521040076e6ac83a87a076a6c2e23143fbff60d58dc0f52e54c0c7
deviceName: 客廳電視
deviceReality: physical
appleTVModel: Apple TV 4K (3rd generation), AppleTV14,1, J255AP
coreDeviceID: 091555FF-9FE8-5A47-B90A-CBDDC737E052
xcodeDestinationUDID: 00008110-000C613A1142801E
tvOS: 26.5 (23L471), Beta
displayModel: LG C3
displayFirmware: not recorded
matchDynamicRangeSetting: enabled in the earlier 2026-07-18 settings row; not re-read immediately before this run
observedDisplayMode: LG C3 HDR indicator activated after explicit player restart
humanVisualConfirmation: pass; color bars and neutral grayscale reported correct
```

LG's published C3 specification lists Dolby Vision, HDR10, and HLG support. The absence of HDR10+ on
this display means the C3 cannot close the separate HDR10+ panel-mode row. See the
[LG C3 product specification](https://www.lg.com/de/tvs-und-soundbars/oled-evo/oled55c39lc/).

## Color-managed fixture identity

The replacement fixture is generated locally from copyright-clean deterministic code. Its retained
16-bit PPM stores nonlinear BT.2020 R'G'B' values: color bars use a 203-nit reference-white scale,
grayscale spans black through 1000 nits, and every component is encoded with the SMPTE ST 2084 OETF.
FFmpeg performs only the BT.2020 non-constant-luminance RGB-to-YCbCr matrix conversion to limited-range
10-bit YCbCr before x265. The generator verifies published PQ/HLG transfer anchors and refuses an
existing output path, malformed dimensions, out-of-range transfer inputs, or a missing tool.

```text
generationCommand: AETHER_ACCEPTANCE_VIDEO_FORMAT=hdr10 AETHER_ACCEPTANCE_DURATION_SECONDS=60 AETHER_ACCEPTANCE_HLS_SEGMENT_SECONDS=4 bash Scripts/generate-hybrid-acceptance-fixture.sh /tmp/aether-hdr10-reference-v2-20260718
fixtureFormat: HEVC Main10 hev1; yuv420p10le; limited range; BT.2020 non-constant; SMPTE ST 2084 PQ
fixtureDurationSeconds: 60
fixtureSegmentCount: 15 video; 15 in each of two AAC stereo renditions
fixtureByteCount: 15753118
fixtureSHA256SUMSFileSHA256: 8009788e60628c77e089d0a28a780064261ebbe1cb8e80c3167a7521e4cd1c3f
masterPlaylistSHA256: ac79f7174e34c46486f516a8d0201f2990243643724c737ce4cfacf2af14a68c
videoInitSHA256: c81932adc475eae760d1b7827c45ccfc93cd86786c373732ecc128635d54fd67
videoSegment000SHA256: 85f57f94d26b9ec74572fef7aed89b11c6106582eb6833523c39c03cd1b2dd19
colorReferencePPMSHA256: d17cda54b3cc512580910a2ded49e7f826848a63bb0773d4accbc6160ecdf7ff
colorReferenceGeneratorSHA256: c6800dfa8a6065d9f101d78ea31bd7e45a17c96390467628fbba6973efc4e69f
provenanceSHA256: b55d70a6e12fe52ef5033cf076275e7314250f9ad3c8a4d92aa5a13ef0b9658d
MDCV: R(34000,16000) G(13250,34500) B(7500,3000) WP(15635,16450), max 1000 nits, min 0.0001 nits
CLLI: MaxCLL 1000, MaxFALL 400
redistribution: generated pattern and sine-wave test media; no third-party audiovisual asset
```

`ffprobe` reads the first decoded frame as Main10 `yuv420p10le`, limited range, BT.2020 NCL,
SMPTE ST 2084, with the expected 24-byte mastering-display and 4-byte content-light metadata. Signal
statistics report 10-bit Y/U/V with legal-range luma `64...725` and no out-of-contract sample range.

## Production-admission device result

The final run used the exact source tree committed as `057e1e7`. Unlike the earlier diagnostic build,
its public capabilities contain only SDR and HDR10 and publish no supported Dolby Vision profile.

```text
preflightRoute: hybridCarrier
preflightReason: hybridHLSManifestMissingCodecs
decodedVideoFormat: hdr10
startupCheckpoint: color-hdr10-passed
startupCarrierTimeSeconds: 1.059552332
startupEnqueuedSampleBuffers: 32
generation: 0 throughout
carrierTimebaseBound: true throughout
renderer: rendering throughout
sessionEndedCarrierTimeSeconds: 60.022267997
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

The first v2 observation also completed all 1440 frames at 60.021 seconds. The player was then
explicitly restarted so the human observer could see the television perform a new HDR handshake; the
HDR indicator activated and the observer reported that the reference colors looked correct. The
production-admission binary was rebuilt afterward and independently completed the exact 60-second row
above.

## Verification

- `bash -n Scripts/generate-hybrid-acceptance-fixture.sh` — pass.
- `python3 -m py_compile Scripts/generate-hybrid-hdr-reference-pattern.py` — pass.
- Small PQ reference conversion — pass; 10-bit limited-range BT.2020 NCL signal statistics.
- Eight-second HLG fixture generation — pass with color-managed HLG provenance.
- Sixteen-second late-HDR10+ fixture generation — pass; first dynamic metadata in segment 2 while the
  first segment remains metadata-free. These generator checks do not admit HLG or HDR10+.
- Focused public-capability, presentation, and stale-preflight tests — pass.
- Full `swift test --quiet` — 421 XCTest tests with 2 skipped and no failures; 740 Swift Testing tests in
  130 suites pass.
- Physical-destination Debug build, install, startup checkpoint, full end of stream, HDR indicator, and
  human visual row — pass.

## No-fallback audit

No fallback was added. Invalid fixture inputs fail generation; a color-startup timeout remains terminal;
unverified HLG/HDR10+/Dolby Vision inputs resolve to typed unsupported before session creation. The
passing HDR10 row never tone-mapped, relabelled, changed player, changed route, changed renderer, or
started another clock.
