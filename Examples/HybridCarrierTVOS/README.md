# Hybrid carrier tvOS acceptance app

This standalone tvOS app exercises AetherEngine's public Hybrid contract without a Syncnext host. It
preflights one explicit seekable HLS or progressive VOD URL, requires the `.hybridCarrier` route, installs the single
`AetherHybridPresentationView` under `AVPlayerViewController.contentOverlayView`, and never starts a
second route after failure.

The automatic scenario verifies the exact carrier timebase through pause, 0.5x, 1x and 2x playback,
forward and backward seeks, decoder pre-roll admission, bidirectional carrier audio selection, and a
complete stop/reopen lifecycle. It emits privacy-safe `AETHER_ACCEPTANCE` records to stdout. Source URLs
and local resource-graph details are not included in formal telemetry.

## Generate a local fixture

From the AetherEngine repository root:

```bash
./Scripts/generate-hybrid-acceptance-fixture.sh
python3 -m http.server 8090 --bind 0.0.0.0 --directory Fixtures/hybrid-sdr-hev1-hls
```

The synthetic fixture is local and gitignored. Preserve its generated `PROVENANCE.txt` and
`SHA256SUMS` for an evidence run. The default graph contains HEVC Main `hev1` video and two selectable
AAC audio renditions. Generation normalizes only the bounded one-tick-per-segment loss caused by
FFmpeg's six-decimal AAC `EXTINF` serialization; a larger audio/video mismatch fails fixture creation.
Do not reuse an older gitignored directory merely because it has the expected name: record the
`SHA256SUMS` file hash and compare it with the intended evidence row before launch. The formal
2026-07-17 SDR dependency-rebuild smoke used
`Fixtures/hybrid-sdr-hev1-hls-v5-multisegment` with graph identity
`cecdf94949e7d80339b51cfef189d0cc65a20a4b5ac4f10ab00cde3c1b140468`; the older local
`Fixtures/hybrid-sdr-hev1-hls` graph is intentionally rejected by current fail-closed preflight.

Set `AETHER_ACCEPTANCE_WEBVTT_SUBTITLES=1` while generating to add one deterministic, timeline-aligned
WebVTT rendition. Launch with `AETHER_ACCEPTANCE_SUBTITLE_AUTORUN=1` to require AVFoundation's native
`.legible` media-selection group, select/deselect/reselect that option, require the selected cue to become
visible in Aether's presentation diagnostics, and prove that the exact carrier clock and sample-buffer
renderer remain healthy. AVKit remains the selection UI; a presentation-only
`AVPlayerItemLegibleOutput` bridge draws its public common-format attributed strings above Aether's real
video because `contentOverlayView` necessarily sits above AVKit's own caption layer. This bridge does not
fetch, parse, independently clock, or select another subtitle source. The physical Remote/XCUITest menu
row is recorded in `Tests/Integration/hybrid-avkit-media-selection-ui-device-evidence-2026-07-18.md`.

To exercise Aether-owned styled subtitles over the same carrier clock, generate the progressive VP9 +
AAC + ASS fixture and serve the `Fixtures` directory from the Mac:

```bash
./Scripts/generate-hybrid-overlay-subtitle-fixture.sh
python3 Scripts/serve-hybrid-acceptance-fixture.py \
  Fixtures/hybrid-vp9-ass-overlay.mkv --port 8090
```

Launch the app with a URL ending in `hybrid-vp9-ass-overlay.mkv` and
`AETHER_ACCEPTANCE_OVERLAY_SUBTITLE_AUTORUN=1`. The row requires one available styled track, an Aether
menu installed in AVKit, explicit select/off/reselect, visible libass pixels before and after an exact
seek-generation rebuild, the single `AVSampleBufferDisplayLayer`, and the bound carrier timebase. Its
final checkpoint is `styled-overlay-selection-passed`. The fixture, provenance, and hashes are local and
gitignored; the script refuses to overwrite them.

To exercise Aether-owned bitmap subtitles, generate the deterministic VP9 + AAC + PGS fixture. The PGS
pixels use a local 5x7 glyph generator, so no third-party font or media is embedded:

```bash
./Scripts/generate-hybrid-bitmap-subtitle-fixture.sh
python3 Scripts/serve-hybrid-acceptance-fixture.py \
  Fixtures/hybrid-vp9-pgs-overlay.mkv --port 8090
```

Launch with `AETHER_ACCEPTANCE_BITMAP_SUBTITLE_AUTORUN=1`. The generator fails if FFmpeg reports any
PGS decode/mux warning or if the resulting stream, 1920x1080 composition canvas, or first-cue PTS differs
from the exact fixture contract. The device row proves cue-off before 1.0 seconds, visible decoded pixels
after the cue begins, a generation-changing seek to 16.5 seconds, explicit Off/reselect, the AVKit
`Aether Subtitles` menu, the single display layer, and the exact carrier timebase. Its final checkpoint is
`bitmap-overlay-selection-passed`.

To verify that a progressive plain-text subtitle remains native to AVKit,
generate the VP9 + AAC + SubRip fixture and serve that single file:

```bash
./Scripts/generate-hybrid-native-subtitle-fixture.sh
python3 Scripts/serve-hybrid-acceptance-fixture.py \
  Fixtures/hybrid-vp9-subrip-native.mkv --port 8090
```

Launch with `AETHER_ACCEPTANCE_PROGRESSIVE_NATIVE_SUBTITLE_AUTORUN=1`.
The row requires one AVFoundation `.legible` option, explicit
select/deselect/reselect, a moving carrier clock, the exact same carrier
timebase, and visible Aether presentation of the carrier item's selected
common-format cue. A host-parsed or independently scheduled text overlay does
not satisfy this plain-text row. Its final checkpoint is
`native-webvtt-selection-passed`.

For local Atmos acceptance, set `AETHER_ACCEPTANCE_ATMOS_EC3_INPUT` to a licensed E-AC-3 JOC
elementary stream. The generator first requires FFmpeg to identify the input as E-AC-3 Atmos, then
creates a default JOC rendition by stream-copy plus an AAC alternate for bidirectional selection. It
records only the source SHA-256 and codec probe in provenance; it never copies the elementary source
into the fixture. Both the source vector and generated HLS remain gitignored and must not be
redistributed unless their license separately permits it.

The generator rewrites FFmpeg's generic six-channel master declaration to `CHANNELS="16/JOC"` only
after the bitstream probe passes. Aether then verifies that declaration against the actual profile-30
descriptor. The normal automatic scenario covers startup, forward/backward seek, JOC-to-AAC and
AAC-to-JOC selection, and stop/reopen. Run the controlled-stall scenario against the same fixture for
the remaining transport row. Telemetry prints the fixed 2 Mbps carrier budget and the observed
peak/average without exposing source URLs or track names.

Set `AETHER_ACCEPTANCE_VIDEO_FORMAT=hdr10` or `hlg` to generate a Main10 diagnostic fixture. HDR10
includes explicit BT.2020/PQ, MDCV, and CLLI signaling; HLG includes BT.2020/ARIB STD-B67 signaling.
Generating or rendering either fixture is not format admission: the physical-device record still needs
panel-mode and human visual evidence before `verifiedVideoFormats` can expand.

Set `AETHER_ACCEPTANCE_VIDEO_FORMAT=hdr10plus` to generate a deterministic PQ fixture whose first HLS
segment contains no HDR10+ metadata and whose ST 2094-40 T.35 payload begins at 12 seconds by default.
Override that point with `AETHER_ACCEPTANCE_HDR10_PLUS_FIRST_FRAME_SECONDS`; it must remain after the
first segment. The generator fails unless `ffprobe` proves the first segment is metadata-free and a
later segment contains recognized HDR10+ metadata.

Set `AETHER_ACCEPTANCE_VIDEO_FORMAT=dolbyvision84` and point
`AETHER_ACCEPTANCE_DOVI_TOOL` at a pinned `dovi_tool` executable to generate the first profile-specific
Dolby Vision fixture. The generator creates an HEVC Main10 BT.2020/HLG base layer, generates P8.4 RPU
metadata for every frame, emits an `hev1` fMP4 HLS presentation with an exact 24-byte `dvvC`, and fails
unless FFmpeg reads profile 8, compatibility ID 4, RPU/BL present, EL absent, uncompressed metadata, and
an RPU on the first frame. Use `AETHER_ACCEPTANCE_COLOR_AUTORUN=1` with
`AETHER_ACCEPTANCE_EXPECTED_VIDEO_FORMAT=dolbyvision` for the technical device row. Production
admission remains unchanged until the device and human panel-mode/visual rows are both recorded.

Set `AETHER_ACCEPTANCE_GEOMETRY_MODE` to `clean_aperture`, `sar_4_3`, `rotation_90`,
`rotation_180`, `rotation_270`, `fps_24000_1001`, or `fps_15` for a deterministic geometry/cadence
fixture. Rotation mode names are Aether's canonical clockwise values; the generator writes FFmpeg's
opposite-sign counter-clockwise display matrix. The 23.976 fixture rounds up to the common 512-video-frame
/ 1001-AAC-frame boundary so the media timelines remain exact.

## Generate the project and build

The checked-in Xcode project is generated from `project.yml`. Regenerate it after changing project
settings:

```bash
xcodegen generate --spec Examples/HybridCarrierTVOS/project.yml
xcodebuild \
  -project Examples/HybridCarrierTVOS/AetherHybridAcceptance.xcodeproj \
  -scheme AetherHybridAcceptance \
  -configuration Debug \
  -destination 'generic/platform=tvOS' \
  -derivedDataPath .build/HybridCarrierTVOSDevice \
  build
```

Install and attach stdout on the physical acceptance Apple TV:

```bash
xcrun devicectl device install app \
  --device <CoreDevice-ID> \
  .build/HybridCarrierTVOSDevice/Build/Products/Debug-appletvos/AetherHybridAcceptance.app

xcrun devicectl device process launch \
  --device <CoreDevice-ID> \
  --console \
  --environment-variables \
  '{"AETHER_ACCEPTANCE_FIXTURE_URL":"http://<Mac-hostname>:8090/master.m3u8","AETHER_ACCEPTANCE_AUTORUN":"1"}' \
  com.qoli.AetherHybridAcceptance
```

Do not set `AETHER_ACCEPTANCE_LOCAL_DIAGNOSTICS` during a formal run. That opt-in switch can reveal a
local resource-graph rejection reason and exists only for fixture construction.

For a physical-remote or XCUITest pass through AVPlayerViewController's native audio/subtitle menus,
also set `AETHER_ACCEPTANCE_AVKIT_UI_EVIDENCE=1`. This hides only the acceptance harness's custom
pause/rate/seek/stop button row so it cannot compete with AVKit's focus environment. It does not change
the player, session, carrier, presentation view, renderer, clock, media-selection groups or route.

The final stdout checkpoint must be `stop-and-reopen-passed`. A terminal failure, a missing checkpoint,
another route, an unbound timebase, or a renderer switch fails the run.

## Controlled origin stall

Use a multi-segment fixture and the deterministic server to delay both audio-rendition copies of one
future segment:

```bash
python3 Scripts/serve-hybrid-acceptance-fixture.py \
  Fixtures/hybrid-sdr-hev1-hls \
  --port 8090 \
  --stall-audio-segment 3 \
  --stall-seconds 9
```

Launch with `AETHER_ACCEPTANCE_STALL_AUTORUN=1` instead of the normal autorun flag. This mode passes only
after AVPlayer reports real carrier stall pressure, Aether rebuilds a later presentation generation on
the same item/timebase, and the carrier clock advances again. Its final checkpoint is
`controlled-stall-recovery-passed`.

Keep this recoverable fixture below the origin loader's ten-second request timeout. A delay of ten
seconds or longer is a typed terminal origin timeout and belongs to the terminal-error matrix, not the
stall-recovery row.

## Color-path candidate run

Use `AETHER_ACCEPTANCE_COLOR_AUTORUN=1` together with
`AETHER_ACCEPTANCE_EXPECTED_VIDEO_FORMAT=hdr10` or `hlg`. The harness requires the decoded diagnostic
format, the single rendering display layer, a bound carrier timebase, enqueued samples, and an advancing
carrier clock. Its final checkpoint is `color-<format>-passed`. This proves an engine/device candidate
only; it does not replace the panel-mode and human visual rows.

For the late-metadata row, launch the HDR10+ fixture with
`AETHER_ACCEPTANCE_LATE_HDR10_PLUS_AUTORUN=1`. The harness requires an initial metadata-free HDR10
state, followed by a nonzero display-layer attachment count and `.hdr10Plus` on the same generation,
carrier item, presentation view, renderer, and carrier timebase binding. Its final checkpoint is
`late-hdr10plus-same-layer-passed`.

## Host-contract negative run

Set `AETHER_ACCEPTANCE_NEGATIVE_CASE` to one of `player`, `gravity`, `automaticDisplayCriteria`,
`presentationOverlay`, or `carrierItem`. The automatic-display-criteria conflict is injected before
`prepare()` because tvOS itself forbids changing that property during full-screen playback. The other
mutations run after playback has an advancing bound carrier clock.

Every case must end at `negative-case-passed` with the documented typed terminal error. Starting another
route, player, renderer, or backend fails the run.

## Geometry and source-cadence run

Use `AETHER_ACCEPTANCE_GEOMETRY_AUTORUN=1` with the matching
`AETHER_ACCEPTANCE_GEOMETRY_MODE`. The harness verifies the renderer's newest admitted source geometry
and frame duration rather than the black carrier canvas or the display-policy snapped refresh rate.
Clean-aperture mode also switches Aether real-video gravity to aspect-fill and proves the AVKit carrier
remains aspect-fit. The final checkpoint is `geometry-<mode>-passed`; clean-aperture mode additionally
requires `geometry-gravity-policy-passed`.
