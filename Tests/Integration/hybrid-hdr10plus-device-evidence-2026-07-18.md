# Hybrid late-HDR10+ physical-device evidence — 2026-07-18

## Result

The late-metadata technical row passes on the physical study-room Apple TV. A deterministic PQ
Main10 HLS source started as metadata-free HDR10, then delivered its first validated ST 2094-40
T.35 payload at source PTS 12.0 seconds. The hardware-decoded sample reached the existing
`AVSampleBufferDisplayLayer` with `kCMSampleAttachmentKey_HDR10PlusPerFrameData`; Aether published
`.hdr10Plus` without changing the Hybrid route, generation, carrier item, presentation view,
renderer, or carrier-timebase binding.

This record does **not** admit HDR10+ for production. Match Dynamic Range and Match Frame Rate were
disabled on the device, so its HDR10+ panel-mode and human visual confirmation remain pending. At the
time of this run `AetherHybridPresentationView.verifiedVideoFormats` remained `[.sdr]`. A later
color-managed LG C3 row independently admits base HDR10, making current admission `[.sdr, .hdr10]`,
but the C3 cannot provide an HDR10+ positive panel row and this document still does not admit HDR10+.
See [`hybrid-hdr10-device-evidence-2026-07-18.md`](hybrid-hdr10-device-evidence-2026-07-18.md).

A later supplemental run enabled both Match settings and captured a non-black framebuffer after the
12-second metadata boundary. It does not prove the external panel's HDR10+ mode, so production
admission and human visual confirmation remain pending. See
[`hybrid-match-content-framebuffer-evidence-2026-07-18.md`](hybrid-match-content-framebuffer-evidence-2026-07-18.md).

## Exact candidate and device

```text
status: technical-pass; panel-mode-and-visual-pending
utcRunDate: 2026-07-18
aetherCandidateCommit: e6acbed47aece755ca35bf00fb73b0164d9f333a
aetherCandidateBaseCommit: c459d6ec9193ab4984bfdb8baa532e72e581fb39
branch: feat/syncnext-hybrid-carrier
xcode: 26.4.1 (17E202)
sdk: AppleTVOS 26.4 (23L236)
configuration: Debug
acceptanceExecutableSHA256: 83ca82ba7fb646550acedb0a1d53ab99cd3e3ccaafc1e796475e24ebaf6b1624
deviceName: 書房電視
deviceReality: physical
appleTVModel: Apple TV 4K (AppleTV6,2; J105aAP)
coreDeviceID: 4F403AE1-B129-5248-BC6E-31DFDD75B422
xcodeDestinationUDID: 771d28ce0d2fe7b0ac1a9fa5d73424b89b54c8a2
tvOS: 26.5 (23L471)
matchDynamicRangeEnabled: false
matchFrameRateEnabled: false
displayModel: not recorded
displayFirmware: not recorded
observedDisplayMode: not recorded
humanVisualConfirmation: pending
```

The signed diagnostic app was built from the candidate tree with one temporary acceptance-only
admission delta: `verifiedVideoFormats` contained `.hdr10` and `.hdr10Plus` for this run. That delta
was restored to `[.sdr]` immediately after the device build and is absent from the candidate commit.
It did not introduce another renderer, route, player, decoder, or clock.

## Fixture identity

The fixture is generated locally, contains only `testsrc2` video plus generated sine-wave AAC, and
remains under a gitignored path. The generator refuses to overwrite an existing fixture and fails
unless `ffprobe` proves that the first segment has no HDR10+ metadata and a later segment has
recognized SMPTE 2094-40 metadata.

```text
generator: Scripts/generate-hybrid-acceptance-fixture.sh
generationCommand: AETHER_ACCEPTANCE_VIDEO_FORMAT=hdr10plus AETHER_ACCEPTANCE_DURATION_SECONDS=20 AETHER_ACCEPTANCE_HDR10_PLUS_FIRST_FRAME_SECONDS=12 bash Scripts/generate-hybrid-acceptance-fixture.sh /tmp/aether-hdr10plus-late-fixture
fixtureFormat: HEVC Main10 hev1; yuv420p10le; BT.2020 non-constant; SMPTE ST 2084 PQ
fixtureDurationSeconds: 20
fixtureByteCount: 7364784
fixtureSHA256SUMSFileSHA256: c844424e3a2e9d95d08ac898b1c2fe219af94113cc558fe6a09680a1dfaa744f
masterPlaylistSHA256: c3bf96e23ecd73caaf3b014b5ea9cace7e1ac220d0bee68eacb4742b49f13572
videoInitSHA256: 3c61c1f6aa00c172612768490725b24daa34cb00aaef403f481b41451ed8068a
metadataFreeSegment000SHA256: 98805780da693c9117bccc53ba8e5c20f7dc9ed819466412cdf82dc2fb929adb
firstDynamicSegment003SHA256: 66da126244bc58cc579a184d7b7780cc5017eec1f60a3b2b02f4801b65d71f62
firstHDR10PlusPOC: 288
firstHDR10PlusPTSSeconds: 12.0
firstDynamicSegment: segment_003.m4s
registeredT35PrefixHex: B5 00 3C 00 01 04
redistribution: generated test media; no third-party audiovisual asset
```

## Automated physical-device observations

The formal console record is local at
`/tmp/AetherHybridHDR10Plus-20260718-1118-console.log`; its SHA-256 is
`a5d35f56dcda47a8a78698c21540c33eb02ab7d416a785631f1d6f0532562b4a`.
It contains no `sessionFailed` or terminal-failure event.

```text
preflightRoute: hybridCarrier
preflightReason: hybridHLSManifestMissingCodecs
startupVideoFormat: hdr10
startupGeneration: 0
startupHDR10PlusAttachedSamples: 0
startupTimebaseBound: true
startupRenderer: rendering
firstAttachmentEvent: videoFormatChanged
firstAttachmentVideoFormat: hdr10plus
firstAttachmentGeneration: 0
firstAttachmentPTSSeconds: 12.0
firstAttachmentCount: 1
samePresentationView: true
sameCarrierItem: true
timebaseBoundAfterAttachment: true
rendererAfterAttachment: rendering
routeSwitchCount: 0
generationChangeCount: 0
rendererSwitchCount: 0
carrierItemSwitchCount: 0
terminalFailureCount: 0
finalCheckpoint: late-hdr10plus-same-layer-passed
carrierDeclaredTransportBudget: 2000000
carrierObservedPeakAtCheckpoint: 201738
carrierObservedAverageAtCheckpoint: 200280
```

The checkpoint is emitted only after the renderer's enqueue target has accepted a sample buffer with
the Apple HDR10+ attachment. It is not inferred from a container label, preflight manifest, decoder
callback, or an attachment created but never submitted to the display layer.

## Verification run

- `bash -n Scripts/generate-hybrid-acceptance-fixture.sh` — pass.
- Focused HDR10+/presentation/session/telemetry tests — pass.
- `swift test` — 735 tests in 130 suites, pass.
- AetherEngine Debug generic tvOS build — pass.
- AetherEngine Release generic tvOS build — pass.
- Signed diagnostic build and install on the physical study-room Apple TV — pass.
- Late-HDR10+ automatic physical-device row — pass twice; formal hashed record above.

## Remaining gate

Before production admission, run HDR10 and late-HDR10+ with Match Dynamic Range enabled and record
the connected display model/firmware, the display's observed HDR mode, and human confirmation that
the real picture is visible with no black frame, incorrect tone map, clipping, color shift, stale
generation, or carrier-video leak. Until that evidence is appended, both formats remain typed
unsupported by the production Hybrid presentation gate.
