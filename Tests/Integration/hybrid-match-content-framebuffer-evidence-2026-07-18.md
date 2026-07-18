# Hybrid Match Content and framebuffer evidence — 2026-07-18

## Result

The study-room Apple TV now has both **Match Dynamic Range** and **Match Frame Rate** enabled. A
physical-device XCUITest then launched the same diagnostic Hybrid acceptance app against independent
60-second HDR10, HLG, late-HDR10+ and Dolby Vision Profile 8.4 fixtures. All four rows reached a bound
carrier timebase, a rendering `AVSampleBufferDisplayLayer`, generation zero and a non-black composited
framebuffer while the native AVKit controls remained present. The late-HDR10+ capture was delayed until
after the fixture's first ST 2094-40 metadata at PTS 12.0 seconds.

This is supplemental device and framebuffer evidence. It is **not panel-mode evidence**: a tvOS
framebuffer screenshot cannot prove that the attached television entered HDR10, HLG, HDR10+ or Dolby
Vision mode, and it cannot establish subjective tone mapping, clipping, color or black-level quality.
The television model/firmware, television OSD and human visual confirmation therefore remained pending
for this capture. At the time, production admission was
`AetherHybridPresentationView.verifiedVideoFormats == [.sdr]`. Later independent LG C3 panel-mode and
human visual rows admit HDR10 and HLG, and a later profile-specific LG C3 row admits Dolby Vision 8.4,
so current production admission is `[.sdr, .hdr10, .hlg, .dolbyVision]` with Profile 8.4 only; this
framebuffer-only record itself supplies no HDR10+ or Dolby Vision admission evidence.

## Exact candidate and device

```text
status: device-settings-and-framebuffer-pass; panel-mode-and-human-visual-pending
utcRunDate: 2026-07-18
aetherCodeCommit: 606efb19c01c17e3d6a516f516ee5e134fce9815
aetherEvidenceCommitBeforeThisRecord: 7ef19c30dd8d46769ddb1ce1822493c6f413bd60
branch: feat/syncnext-hybrid-carrier
xcode: 26.4.1 (17E202)
sdk: AppleTVOS 26.4 (23L236)
configuration: Debug, temporary diagnostic color admission only
acceptanceLauncherSHA256: 9785951905240d35db1528f0e827594aadd204dd8f01e2b85d14c6ff6a68bd6b
acceptanceDebugDylibSHA256: 81a36829cc4fd5e0393ad8a7888f4e53df541f930f6007153e0862be1cb98381
deviceName: 書房電視
deviceReality: physical
appleTVModel: Apple TV 4K (AppleTV6,2; J105aAP)
coreDeviceID: 4F403AE1-B129-5248-BC6E-31DFDD75B422
xcodeDestinationUDID: 771d28ce0d2fe7b0ac1a9fa5d73424b89b54c8a2
tvOS: 26.5 (23L471)
matchDynamicRangeEnabled: true
matchFrameRateEnabled: true
displayModel: not recorded
displayFirmware: not recorded
observedDisplayMode: not recorded
humanVisualConfirmation: pending
```

The diagnostic app was built with HDR10, HLG, HDR10+ and Dolby Vision Profile 8.4 admitted only for
this acceptance run. The temporary admission delta was removed after the build. It did not add a route,
decoder, renderer, player, audio path or clock.

## Match Content settings evidence

An ephemeral XCUITest attached to the physical device's `com.apple.TVSettings`, enabled the two rows
only when their current value was `關閉`, and then waited until both values read `開啟`.

```text
settingsTest: TVSettingsProbeTests/testEnableAndVerifyMatchContent
settingsResult: pass
matchDynamicRangeRow: 符合動態範圍 = 開啟
matchFrameRateRow: 符合格率 = 開啟
settingsHierarchyAttachment:
  /tmp/TVSettingsProbe/MatchContentEnabledAttachments/D9CCD8AF-B978-4139-9043-FD11EFA7EB17.txt
settingsHierarchySHA256: dd2e11dbde4dc5b7b095c75db260bcaa8c521c9d9e980e2089d09c51c6f88a59
settingsXCResult:
  /tmp/TVSettingsProbe/DerivedData/Logs/Test/Test-TVSettingsProbe-2026.07.18_1-08-15-+0800.xcresult
```

The probe is a local evidence harness, not a product or package dependency. The Computer Use service
was unavailable for this run, so XCUITest was used to read and operate the actual Settings UI.

## Format-specific console checkpoints

The long-fixture console runs establish the decoded color format. They were recorded from the same
corrected diagnostic app before the framebuffer capture run.

```text
HDR10:
  fixtureSHA256SUMSFileSHA256: 3589c2f4234f786d38b137423d1c56895890f68f28599b6398a87124909c7155
  checkpoint: color-hdr10-passed
  generation: 0
  timebaseBound: true
  renderer: rendering
  enqueuedAtCheckpoint: 74
  consoleSHA256: a6744df64bf2448c01d6e1a691db07de6cfffdc5c0c0e0f526c1f402f33d2ce7

HLG:
  fixtureSHA256SUMSFileSHA256: 69ae905c2ee2689fc649f7afb5bae15800156ef57a4cc79571986deb8bf5bd6c
  checkpoint: color-hlg-passed
  dolbyVisionConfiguration: none
  dolbyVisionProfile84BaseLayerVerified: false
  generation: 0
  timebaseBound: true
  renderer: rendering
  enqueuedAtCheckpoint: 74
  consoleSHA256: 0d7e954a42df0c2c3a656355447c1a17f9f917543261456a0352a983835e3cdf

late HDR10+:
  fixtureSHA256SUMSFileSHA256: b2af5ce3dac9f5ea59a1bf52b40562dfddd3021720d0c7e6df3c2488906e6dbe
  startupFormat: hdr10
  firstHDR10PlusAttachmentPTSSeconds: 12.0
  checkpoint: late-hdr10plus-same-layer-passed
  generation: 0
  samePresentationView: true
  sameCarrierItem: true
  timebaseBound: true
  renderer: rendering
  consoleSHA256: 3631182365b973cf6a37f9ebfe46e22ee6f6137f064977577b3fa0c6303c968f

Dolby Vision Profile 8.4:
  fixtureSHA256SUMSFileSHA256: e23b93464f870a820b949b32ed43c7aed527aad8a5e296cb231a39d494ba9c88
  exactConfiguration: version1.0,profile8,level3,rpu1,el0,bl1,compat4,compression0
  decoderDVVCAdmission: true
  videoToolboxPerFrameMetadataPropagationAccepted: true
  checkpoint: color-dolbyvision-passed
  generation: 0
  timebaseBound: true
  renderer: rendering
  enqueuedAtCheckpoint: 74
  consoleSHA256: 09cb3d5de348750627ad52081e473dbdf904f4e059d55a0a79b4fb04b965343c
```

## Framebuffer capture evidence

The physical-device XCUITest result contains four passing tests and no failures. Each test required an
accessible `renderer=rendering` diagnostic before capture. HDR10, HLG and Dolby Vision were allowed to
settle for five seconds; late HDR10+ was allowed to settle for 17 seconds so its capture occurred after
the first dynamic-metadata timestamp.

```text
xcresult:
  /tmp/TVSettingsProbe/DerivedData/Logs/Test/Test-TVSettingsProbe-2026.07.18_1-18-35-+0800.xcresult
result: pass
passedTests: 4
failedTests: 0
device: 書房電視; physical Apple TV 4K; tvOS 26.5 (23L471)
attachmentManifestSHA256: 8e472a7afb7d4937fb10e5b44a9e79f13ec78fae1632eca03f4fc5601671d801

HDR10:
  carrierTimeAtCaptureSeconds: 5.052
  enqueuedAtCapture: 127
  screenshotSHA256: da666e29b54889670112b1327d8ea6816e1b3939e3923c492d07c3dbef820a37
  hierarchySHA256: f32a5e7830d3d308203be8ac08fd7b54fe3c7dbd3ff4c423c89c69101352f2c1

HLG:
  carrierTimeAtCaptureSeconds: 5.039
  enqueuedAtCapture: 127
  screenshotSHA256: 91135e846ed5f1c98703d7c3577caf1ed3125121e216b071806552395c1e755c
  hierarchySHA256: d9b7fe4e12e0f47d86bef2e090b36d423b3fe9965200110fa160364fa2521b12

late HDR10+:
  carrierTimeAtCaptureSeconds: 16.684
  enqueuedAtCapture: 407
  screenshotSHA256: d557426583a77cfb28159f9f8cd0ed5213ea2dc05b3af019936af0f188728884
  hierarchySHA256: 00f32f4d7063bc3e56370360fdf4f03bf9b4a19e273ba98e7af3957d92732134

Dolby Vision Profile 8.4:
  carrierTimeAtCaptureSeconds: 5.054
  enqueuedAtCapture: 127
  screenshotSHA256: f16696c900ee84c885d5395dfd0478dc0c7964e9b2ac3d11cc6db5e55a84450e
  hierarchySHA256: a8907beb924453198707135e21f8de43e9a24ccecc0ddd10aba552cb2808ece9
```

All four screenshots contain the generated moving color bars, path, step and checkerboard rather than
the black carrier. The AVKit transport controls are visible over the single Aether presentation view.
The accessibility hierarchies independently record route `hybridCarrier`, generation zero, a bound
timebase, renderer `rendering`, zero pending frames and increasing enqueued counts.

## Remaining gate

Before any non-SDR format is admitted in production, record the connected display model and firmware,
observe the television/receiver format indicator for each independent row, and obtain a human visual
confirmation covering picture presence, correct color/tone mapping, highlights, black level, clipping,
frame-rate transition and absence of carrier/video flashes. Dolby Vision confirmation must explicitly
name Profile 8.4; it must not be generalized to another profile.

Fallback added: **no**. A missing or contradictory format contract, unavailable carrier timebase,
metadata-propagation rejection, renderer failure or unverified Dolby Vision profile remains a typed
failure. No Metal renderer, second display layer, route change, base-layer-only presentation, tone map
or legacy player is introduced by this evidence run.
