# Hybrid late-HDR10+ physical-device evidence — 2026-07-18

## Result

The late-metadata technical row passes on the physical study-room Apple TV. A deterministic PQ
Main10 HLS source started as metadata-free HDR10, then delivered its first validated ST 2094-40
T.35 payload at source PTS 12.0 seconds. The hardware-decoded sample reached the existing
`AVSampleBufferDisplayLayer` with `kCMSampleAttachmentKey_HDR10PlusPerFrameData`; Aether published
`.hdr10Plus` without changing the Hybrid route, generation, carrier item, presentation view,
renderer, or carrier-timebase binding.

A supplemental run at the final Syncnext integration pin `c17a8f56f2bcb13bf8eb3b3c8d523807b8a03767`
reproduces that technical pass through end of stream. It does not change the production-admission
result below.

This record does **not** admit HDR10+ for production. Match Dynamic Range and Match Frame Rate were
disabled on the device, so its HDR10+ panel-mode and human visual confirmation remain pending. At the
time of this run `AetherHybridPresentationView.verifiedVideoFormats` remained `[.sdr]`. A later
color-managed LG C3 rows independently admit base HDR10 and HLG, and a later profile-specific LG C3 row
admits Dolby Vision Profile 8.4. Current video-format admission is therefore
`[.sdr, .hdr10, .hlg, .dolbyVision]` with Dolby Vision restricted to `[.profile84]`, but the C3 cannot
provide an HDR10+ positive panel row and this document still does not admit HDR10+.
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

## Final integration-pin technical rerun — 2026-07-18

The final Aether source pin used by Syncnext was rerun on the approved study-room Apple TV after the
Native `audioAnalysisStream` work landed. The production source stayed at
`verifiedVideoFormats = [.sdr, .hdr10, .hlg, .dolbyVision]`. As in the earlier technical run, the
signed diagnostic app was built with one temporary acceptance-only `.hdr10Plus` admission line; that
line was removed immediately after the app build and is absent from the clean `c17a8f56` worktree.

```text
status: technical-pass; panel-mode-and-visual-impossible-with-current-equipment
utcRunDate: 2026-07-18
utcEvidenceRecordedAt: 2026-07-18T14:11:27Z
aetherSourceRevision: c17a8f56f2bcb13bf8eb3b3c8d523807b8a03767
acceptanceDelta: one temporary .hdr10Plus verifiedVideoFormats entry; not committed
acceptanceExecutableSHA256: bd5470264dd0c56570a5ec83348254c0c86fe81b27d03e60e02b6a93962052bc
xcode: 26.4.1 (17E202)
sdk: AppleTVOS 26.4 (23L236)
configuration: Debug
deviceName: 書房電視
deviceReality: physical
appleTVModel: Apple TV 4K (AppleTV6,2; J105aAP)
coreDeviceID: 4F403AE1-B129-5248-BC6E-31DFDD75B422
xcodeDestinationUDID: 771d28ce0d2fe7b0ac1a9fa5d73424b89b54c8a2
tvOS: 26.5 (23L471)
displayModel: not HDR10+-capable household equipment
observedDisplayMode: not available
humanHDR10PlusVisualConfirmation: impossible with current equipment
```

The rebuilt deterministic fixture retains a metadata-free first segment and begins validated
ST 2094-40 at POC 288 / source PTS 12.0 seconds:

```text
fixtureByteCount: 13593454
fixtureSHA256SUMSFileSHA256: baee10013bc86c4b67eafeb5b5c9350dd62f41b64d583b0a62cd46ec67b62c57
masterPlaylistSHA256: 7eb097557c9e6733ee9c07c93027c0ccd802f68f31457498d05359b7848c481f
provenanceSHA256: 22c2103bdb972bc8cf795c083f40c7df5f4bd834f3fe43a1344881fa2b175a2d
colorReferenceSHA256: d17cda54b3cc512580910a2ded49e7f826848a63bb0773d4accbc6160ecdf7ff
videoInitSHA256: 83b6cb1f1ac9fd382eaf0dd7e5c9dd2f15e5983fe4cb84cd3123c0364957bbe5
metadataFreeSegment000SHA256: 0d6f812ba557269bdb364c53b7e53271cee9363d844e15a4ba41e1895b3ce3e2
firstDynamicSegment003SHA256: cee4748c8b0a2a5d42aa339e6d59239752f49e9c7f82340f1c85070b85f61c2d
redistribution: generated pattern and sine-wave test media; no third-party audiovisual asset
```

The privacy-safe transcript is retained at
`/Volumes/Data/Github/SyncnextProjects/.artifacts/AetherHDR10Plus/c17a8f56/study-device-technical-transcript.log`
with SHA-256 `2f26db6054b0dcd57b2e5074a14ea7034c7a3c5bdc8ad26ffebf6fc5abd77ea4`.
It contains no source URL, path, header, cookie, credential or media bytes.

```text
preflightRoute: hybridCarrier
preflightReason: hybridHLSManifestMissingCodecs
startupVideoFormat: hdr10
startupGeneration: 0
startupHDR10PlusAttachedSamples: 0
firstAttachmentVideoFormat: hdr10plus
firstAttachmentGeneration: 0
firstAttachmentPTSSeconds: 12.0
samePresentationView: true
sameCarrierItem: true
timebaseBoundAfterAttachment: true
rendererAfterAttachment: rendering
finalCheckpoint: late-hdr10plus-same-layer-passed
endOfStream: pass at carrierTime 20.033891251
finalEnqueuedSamples: 480
finalHDR10PlusAttachedSamples: 192
carrierDeclaredTransportBudget: 2000000
carrierObservedPeak: 201738
carrierObservedAverage: 200294
carrierObservedSegments: 5
unexpectedRouteSwitchCount: 0
unexpectedRendererSwitchCount: 0
terminalFailureCount: 0
```

An attempted Xcode screenshot taken only after end of stream captured the Apple TV screen saver, not
the acceptance app. It is explicitly excluded and supports no display claim. More importantly, a
screen capture or framebuffer could only prove a non-black submitted frame; it cannot prove that the
external television entered HDR10+ mode.

## Remaining gate

Base HDR10 now has separate passing LG C3 panel-mode and human visual evidence. Before HDR10+
production admission, rerun the late-metadata row on a confirmed HDR10+-capable display and record its
model/firmware, observed HDR10+ mode, and human confirmation that the real picture is visible with no
black frame, incorrect tone map, clipping, color shift, stale generation, or carrier-video leak. The LG
C3 cannot close that positive row, and the owner has confirmed that no household display can supply
HDR10+ output evidence. Further runs on the existing equipment cannot close this gate and must not be
reported as successful HDR10+ validation. Until a compatible panel becomes available and its evidence
is appended, HDR10+ remains typed unsupported by the production Hybrid presentation gate.
