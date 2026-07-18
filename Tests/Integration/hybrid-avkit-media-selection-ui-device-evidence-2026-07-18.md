# Hybrid AVKit media-selection UI physical-device evidence — 2026-07-18

## Result

The physical study-room Apple TV passes native AVKit media-selection UI rows for both audio and text
subtitles. A Remote-driven XCUITest opened AVPlayerViewController's own Audio and Subtitles panels,
selected each required option in both directions, reopened the panels after carrier-item replacement,
and verified AVKit's selected checkmarks. Real video remained visible through the one Aether-owned
`AVSampleBufferDisplayLayer`; each rebuilt generation was bound to the carrier item timebase and the
renderer remained `rendering`.

The audio row used the strict E-AC-3 JOC/Atmos plus AAC alternate fixture, not two interchangeable AAC
tracks. The subtitle row used a native HLS WebVTT rendition and proves Off → On (English) → Off → On,
including visible common-format cue presentation above real video. Styled and bitmap subtitles remain
owned by Aether's custom AVKit menu and are covered by their separate evidence rows.

This closes the AVKit menu visibility and Remote-selection rows. Audible output and the downstream
television/AVR Atmos indicator remain human observations; this record does not infer them from UI state.

## Exact candidate and device

```text
status: avkit-audio-and-native-subtitle-ui-pass; audible-and-atmos-indicator-pending
utcRunDate: 2026-07-18
aetherCommit: 1709459
branch: feat/syncnext-hybrid-carrier
xcode: 26.4.1 (17E202)
sdk: AppleTVOS 26.4 (23L236)
configuration: Debug; production SDR capability matrix
acceptanceLauncherSHA256: d7e30a756eb7bad560551fa72de8f087bc03326c7aae3c16e65dfff40fa44c27
acceptanceDebugDylibSHA256: f39f80367f6f428e457e35777e9dbf911350fa435698e27a2d709076b459fcfa
deviceName: 書房電視
deviceReality: physical
appleTVModel: Apple TV 4K (AppleTV6,2; J105aAP)
coreDeviceID: 4F403AE1-B129-5248-BC6E-31DFDD75B422
xcodeDestinationUDID: 771d28ce0d2fe7b0ac1a9fa5d73424b89b54c8a2
tvOS: 26.5 (23L471)
```

The committed `AETHER_ACCEPTANCE_AVKIT_UI_EVIDENCE=1` mode hides only the acceptance harness's custom
transport button row. It leaves AVPlayerViewController, the Aether session, carrier item, media-selection
groups, route, presentation view, renderer, audio path and clock unchanged. No temporary HDR/Dolby
Vision admission was used; the tests ran against production-admitted SDR Hybrid sources.

## Native AVKit audio row

The fixture is the same strict JOC graph used by the existing startup/seek/stall/stop device matrix.
Its default English rendition is the verified E-AC-3 profile-30 stream-copy path advertised as
`CHANNELS="16/JOC"`; Spanish is the AAC alternate. The source bitstream and package remain local under
their testing terms.

```text
fixtureGraphIdentitySHA256: 5c2880748e03d2d59b621be4f69bc11f08c31331903e79b1d63ed30bc606dcf2
sourceVectorSHA256: 9ffe348a4a666b3f7eec27ad41bad955d4f84e0802ca62ea6dd06eed579b6c45
defaultRendition: English; E-AC-3 JOC; 16/JOC; stream-copy
alternateRendition: Spanish; AAC stereo
initialSelection: English
remoteSelectionAway: English JOC -> Spanish AAC; pass
generationAfterSelectionAway: 1
remoteSelectionReturn: Spanish AAC -> English JOC; pass
generationAfterSelectionReturn: 2
routeAfterEachSelection: hybridCarrier
carrierTimebaseBoundAfterEachSelection: true
rendererAfterEachSelection: rendering
pendingFramesAfterEachSelection: 0
```

The XCUITest required `AVAudibleSettings` to receive real tvOS focus before pressing Select. It then
required AVKit's `selected, Spanish` and `selected, English` accessibility states after reopening the
native panel following each carrier generation rebuild.

```text
xcresult:
  /tmp/TVSettingsProbe/DerivedData/Logs/Test/Test-TVSettingsProbe-2026.07.18_1-52-34-+0800.xcresult
test: TVSettingsProbeTests/testProbeAVKitAudioMenu
result: pass; 1 passed; 0 failed
attachmentManifestSHA256: eac4584526d3c6857b52d01d338467080bf2767369449a8045381aee41115097

Spanish selected:
  screenshotSHA256: 3ebdc16110f6b275848a5250fdc175af1f0fa029ed6886d8e8214524b50f5346
  hierarchySHA256: 4cf3f7e25e46e5efc6192456ec629d6103d1f4d262614d268ac7e7daec18eeda
  carrierTimeSeconds: 10.267
  generation: 1
  enqueuedFrames: 262

English JOC restored:
  screenshotSHA256: adbe3385532433917454dfe2479de6577625167743930e48e21b34aade477317
  hierarchySHA256: 8060cc7859d9ec8293d841f92f9fc487c1e0c5ed0a9ca3d74ef4d1147ea04145
  carrierTimeSeconds: 17.184
  generation: 2
  enqueuedFrames: 435
```

The language labels are AVKit presentation labels. JOC identity is established by the exact fixture
hash, the independently probed profile-30 bitstream and Aether's strict manifest/bitstream admission;
it is not inferred from the word “English”.

## Native AVKit WebVTT row

The fixture publishes one English WebVTT rendition in the source-bound HLS `SUBTITLES` group. The
carrier republishes that rendition as an AVFoundation legible option; Aether's presentation-only bridge
renders the selected carrier item's common-format cue above real video.

```text
fixtureGraphIdentitySHA256: 26ff6fcdbe484cf5974694a5e4cab3637eed15d5cd167cd75ebde7b4ff2a15b3
subtitleRenditions: one English WebVTT
initialSelection: Off
remoteSelectionOn: pass; visible cue present
generationAfterFirstOn: 1
remoteSelectionOff: pass; cue absent
generationAfterOff: 2
remoteReselectionOn: pass; visible cue present
generationAfterReselection: 3
routeAfterEachSelection: hybridCarrier
carrierTimebaseBoundAfterEachSelection: true
rendererAfterEachSelection: rendering
pendingFramesAfterEachSelection: 0
```

The XCUITest required `AVLegibleSettings` to receive focus, proved AVKit exposed On, Off and
Language: English, then required AVKit's selected state after every Remote action. Both On captures
show generated WebVTT text above real video; the Off capture has no cue.

```text
xcresult:
  /tmp/TVSettingsProbe/DerivedData/Logs/Test/Test-TVSettingsProbe-2026.07.18_1-49-26-+0800.xcresult
test: TVSettingsProbeTests/testProbeAVKitNativeSubtitleMenu
result: pass; 1 passed; 0 failed
attachmentManifestSHA256: 832dee4ac64e92ad2cdd11e8a7b56806d94a9ee826e3f94d3eab4d6c5d357749

English enabled:
  screenshotSHA256: e60e39d8605555cc9199eb092afb014e2dc0f4cca97f351029cb71f21c3cc5e8
  hierarchySHA256: ef8db3e6e9e7f2bc65831bdd4983f8aeda589c899b43832e7ce3c1cbd52e9be1
  generation: 1
  selectedState: On
  cue: Aether native WebVTT segment 2

Off selected:
  screenshotSHA256: 30120c6605bd57b0c01359fe54a778a72d3b132889fa18ba1c5d4a617f3e21a4
  hierarchySHA256: d8890fabdf287a18b2b642b8a61f0bbc17b735fbfd526aaee6ec9f6992368005
  generation: 2
  selectedState: Off
  cue: absent

English reselected:
  screenshotSHA256: 5ae9f63d5999cafecbcbfbb2eca31b8d0a96c842e95ed4078413cf1ba6044086
  hierarchySHA256: ee0091977ca8590ce2006a4651a3dde68931d40097e5e90f4b5366e217cdcaa3
  generation: 3
  selectedState: On
  cue: Aether native WebVTT segment 4
```

## Aether styled-subtitle custom AVKit menu row

The progressive VP9/AAC/ASS fixture uses Aether's overlay path and the public
`transportBarCustomMenuItems` API, not AVFoundation's native legible group. The existing automatic
physical-device row proves real libass pixels before and after seek, explicit Off and reselect. The
supplemental Remote XCUITest closes the separate custom-menu visibility and interaction row.

```text
fixtureSHA256: d016beb1b3c142a2b877591dd359c68b63d4f92cdc13120aaea48427a98ffaf5
fixtureProvenanceSHA256: 79954abf8f0f23c8d4213f6fbcc04c9eadb87c43c8a69fc6a22b798ca13343df
sourceKind: progressive
preflightRoute: hybridCarrier
menuCell: Aether Subtitles
menuOptions: Off; Aether Styled English
initialUIState: selected, Aether Styled English
remoteSelectionOff: pass
remoteReselectionStyled: pass
generationThroughoutUISelection: 1
carrierTimebaseBound: true
renderer: rendering
pendingFrames: 0
```

The fixture reached its finite 32.022-second end while the menu was open; the final `rate=0.0` is the
normal VOD end and the display layer remained healthy. The custom-menu screenshots establish AVKit UI
state only. Styled pixel visibility is established independently by the automatic row and is not
inferred from a menu checkmark.

```text
xcresult:
  /tmp/TVSettingsProbe/DerivedData/Logs/Test/Test-TVSettingsProbe-2026.07.18_2-03-48-+0800.xcresult
test: TVSettingsProbeTests/testProbeAVKitStyledSubtitleCustomMenu
result: pass; 1 passed; 0 failed
attachmentManifestSHA256: 63fc1d048b965309f7092a71e4ee633a77eedbe85def30edd6d7c7142ad670be

Off selected:
  screenshotSHA256: 2126bdbde10ac6c421a846f384da86611e57d5b06744983374f74abf5c6fe894
  hierarchySHA256: 880c51830d4a163f35c34ddd82819ade7f53b31aadbe6a266adef3af6369bdad

Styled reselected:
  screenshotSHA256: d58dd499ae0bb2eb028b8c36ee7795079f93c737d63386c3b01ed331d3a694e1
  hierarchySHA256: 1484d5e38124efe157dacb9acf7844b2a2f5aeed082fbff96d4c2af804080b6c
```

## Verification and remaining human row

- Physical study-room Apple TV app build/install — pass.
- Native AVKit JOC/AAC bidirectional Remote selection — pass.
- Native AVKit WebVTT Off/On/Off/On Remote selection and visible cue — pass.
- Aether custom AVKit styled-subtitle menu Off/reselect — pass.
- Same Hybrid route, bound carrier timebase and rendering sample-buffer layer after each rebuild — pass.
- Audible JOC/AAC change and downstream Atmos indicator — pending human observation.

Fallback added: **no**. Missing AVKit media-selection groups/options, missing focusable native controls,
selection that does not rebuild the expected generation, a lost carrier timebase or a renderer/session
failure fails the evidence row. No host-created replacement menu is used for native audio or WebVTT,
and no player, route, audio renderer, video renderer or clock fallback was added. Styled/bitmap formats
continue to use only the explicitly required Aether-owned overlay and custom AVKit menu.
