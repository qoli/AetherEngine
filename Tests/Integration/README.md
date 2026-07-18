# Integration harnesses

Checks that need a running engine + a real media file, so they cannot run under `swift test`.

## Hybrid geometry / display-criteria tvOS device gate

[`hybrid-display-device-acceptance.md`](hybrid-display-device-acceptance.md) locks the physical-tvOS
geometry, AVPlayerViewController writer, Match Frame Rate, HDR/HLG/Dolby Vision and teardown evidence.
The source-level sample-buffer timing and metadata contract is implemented. A 2026-07-17 physical-device
run passes the automated SDR clock, seek, pre-roll admission, bidirectional audio selection,
recoverable origin-stall, geometry/cadence, host-negative, native WebVTT selection and visible-cue
presentation, E-AC-3 JOC, styled ASS and PGS bitmap overlay select/seek/off/reselect, plus stop/reopen
sub-matrix. The 2026-07-18 late-HDR10+ row also proves that hardware-decoded ST 2094-40 reaches the
same display layer at PTS 12.0 without a route, generation, carrier-item, renderer, or timebase change.
The Dolby Vision Profile 8.4 row now passes exact configuration/base-layer admission,
VideoToolbox metadata-propagation acceptance and same-layer enqueue. A supplemental
2026-07-18 physical-device run also records Match Dynamic Range and Match Frame Rate enabled and four
non-black, bound-timebase framebuffer captures. Native AVKit Audio and WebVTT menu visibility plus
Remote-driven bidirectional selection now passes on the same device, and the living-room JOC → AAC → JOC
Atmos-output round trip passes. The living-room LG C3 HDR10 row now also passes panel-mode and human
visual confirmation with a color-managed BT.2020/PQ reference. The following color-managed HLG row
also passes the LG C3 HDR indicator and human visual check. Finally, the 60-second color-managed
Profile 8.4 fixture activates the LG C3's explicit Dolby Vision mode, looks correct to the human
observer, and reaches end of stream with 1440 frames on the same bound display layer. Production
admission is therefore `[.sdr, .hdr10, .hlg, .dolbyVision]`, with Dolby Vision restricted to
`[.profile84]`. HDR10+ remains pending on a compatible display; the LG C3 cannot provide that positive
panel row and the owner has confirmed that no household display can provide it. A final-pin
`c17a8f56` study-device rerun nevertheless closes the exact-source late-T.35 technical row through end
of stream; it does not change production admission. See
[`hybrid-display-device-evidence-2026-07-17.md`](hybrid-display-device-evidence-2026-07-17.md) and
[`hybrid-hdr10-device-evidence-2026-07-18.md`](hybrid-hdr10-device-evidence-2026-07-18.md),
[`hybrid-hlg-device-evidence-2026-07-18.md`](hybrid-hlg-device-evidence-2026-07-18.md),
[`hybrid-hdr10plus-device-evidence-2026-07-18.md`](hybrid-hdr10plus-device-evidence-2026-07-18.md), and
[`hybrid-dolby-vision-profile84-device-evidence-2026-07-18.md`](hybrid-dolby-vision-profile84-device-evidence-2026-07-18.md), plus
[`hybrid-match-content-framebuffer-evidence-2026-07-18.md`](hybrid-match-content-framebuffer-evidence-2026-07-18.md) and
[`hybrid-avkit-media-selection-ui-device-evidence-2026-07-18.md`](hybrid-avkit-media-selection-ui-device-evidence-2026-07-18.md).
No unverified
color format may be added to
`AetherHybridPresentationView.verifiedVideoFormats`.

## Hybrid Atmos tvOS device gate

[`hybrid-atmos-device-acceptance.md`](hybrid-atmos-device-acceptance.md) defines the physical-tvOS
E-AC-3 JOC / Atmos fixture, start/seek/track-switch/stall matrix, privacy-safe telemetry evidence,
and the rule for reopening the fixed 2 Mbps policy. The automated physical-device startup, seek,
bidirectional JOC/AAC selection, recoverable stall and stop/reopen rows pass on the study Apple TV.
The acceptance generator now packet-repeats a shorter licensed JOC vector under stream-copy so the
requested human-observation duration is not silently truncated; 40-second and 192-second equal-segment
fixtures pass exact duration/profile/provenance checks.
The mini acceptance app is destination-built, installed and technically running on the living-room
Apple TV, which owns the final downstream audio-chain row. The first 2026-07-18 human observation did
not activate Atmos; after rebuilding, reinstalling and relaunching the same dual-rendition stream-copy
graph, the LG C3 activated Dolby Atmos normally. A private-fixture diagnostic also proves byte-identical
JOC access units and `dec3` across the source/carrier remux. The same relaunched run closes the human
round trip: `audio_2` did not present as Atmos and returning to `audio_1` restored Atmos, matching the
recorded JOC generation 0 → AAC generation 1 → JOC generation 2 selection sequence. The Atmos device
sub-gate therefore passes. A one-time end-of-stream presentation failure near 185.557 seconds did not
recur in three controlled study-Apple-TV runs: 24-second generation 0, 24-second generation 4, and the
exact 192-second generation-4 graph all reached `sessionEnded` with the renderer still `rendering`. The
exact long rerun completed all 48 carrier segments at 192.039728 seconds with no fallback. Aether retains
privacy-safe renderer-failure boundary diagnostics, but no unproved recovery or functional fix was added.

## Hybrid native WebVTT tvOS device gate

The standalone `Examples/HybridCarrierTVOS` app and local fixture generators exercise both real-source
HLS WebVTT through graph-bound preflight and a progressive VP9 Matroska source carrying SubRip. Both
are republished through the carrier's AVFoundation `.legible` selection group. The 2026-07-17 study
Apple TV runs pass select/deselect/reselect while retaining the same route, carrier clock and
sample-buffer renderer. HLS source `DEFAULT`/`AUTOSELECT`/`FORCED` values and progressive container
selection semantics are preserved by the carrier master. The 2026-07-18 exact `78b6418` run also proves
that Aether's presentation-only legible-output bridge places the selected common-format cue above the
real-video layer; AVKit still owns the menu and carrier selection. The later exact `1709459` physical
XCUITest closes AVKit menu visibility and Remote-driven Off/On/Off/On selection. Bitmap/styled overlay
selection is not covered by this row. Progressive visible-cue placement also passes on the study Apple
TV. See
[`hybrid-native-webvtt-device-evidence-2026-07-18.md`](hybrid-native-webvtt-device-evidence-2026-07-18.md).

## Hybrid styled subtitle overlay tvOS device gate

The standalone app's progressive VP9 + ASS mode exercises Aether's public overlay-track contract,
AVKit custom-menu installation, real libass pixel output, explicit Off/reselect, and an exact seek
generation on the same carrier timebase and real-video display layer. The 2026-07-17 study Apple TV run
passes the automated row. The later exact `1709459` Remote XCUITest also proves the visible `Aether
Subtitles` custom menu and Off/reselect states. A copyright-clean bitmap-subtitle physical fixture was
originally pending; the deterministic fixture and physical decoded-pixel row now pass in
[`hybrid-progressive-subtitle-device-evidence-2026-07-18.md`](hybrid-progressive-subtitle-device-evidence-2026-07-18.md) and
[`hybrid-avkit-media-selection-ui-device-evidence-2026-07-18.md`](hybrid-avkit-media-selection-ui-device-evidence-2026-07-18.md).

## Hybrid bitmap subtitle overlay tvOS device gate

The standalone app's copyright-clean VP9 + PGS mode verifies the public overlay-track contract, the
AVKit `Aether Subtitles` custom menu, cue-off before its authored start, decoded bitmap pixels, exact
composition placement, seek-generation rebuild, explicit Off/reselect, and the same carrier timebase and
real-video display layer. The 2026-07-18 study Apple TV automated and XCUITest visual rows pass. No text
conversion, host parser, second clock, second video renderer, or playback fallback is involved. See
[`hybrid-progressive-subtitle-device-evidence-2026-07-18.md`](hybrid-progressive-subtitle-device-evidence-2026-07-18.md).

## `avplayer-open-check.swift` (#15, E8)

Proves AVPlayer can OPEN the loopback HLS master that carries the native WebVTT `SUBTITLES`
rendition, reaches `.readyToPlay`, and exposes at least one legible (subtitle) media-selection
option. This is the open-time guard #55 lacked: muxing timed text into the A/V fMP4 silently
failed the AVPlayer open, so the conformant separate-rendition shape needs an explicit
"does it open and expose the option" check.

The harness imports only Foundation + AVFoundation (never AetherEngine): it talks to the engine
over the loopback HTTP server exactly like a real client, so it validates the served bytes.

### What you need

A media file with at least one embedded TEXT subtitle track (subrip / mov_text / ASS; not a
bitmap track like PGS/VOBSUB). `Fixtures/user/embedded-subs.mkv` is one, but `Fixtures/` is
gitignored (local-only). Generate an equivalent in a few seconds with ffmpeg:

```bash
# 5s 1080p h264 test pattern + a subrip text subtitle track muxed into MKV
printf '1\n00:00:00,500 --> 00:00:02,000\nhello from a text subtitle\n\n2\n00:00:02,500 --> 00:00:04,500\nsecond cue\n' > /tmp/subs.srt
ffmpeg -y -f lavfi -i testsrc=duration=5:size=1920x1080:rate=24 \
       -i /tmp/subs.srt \
       -c:v libx264 -pix_fmt yuv420p -c:s srt \
       /tmp/embedded-subs.mkv
# sanity: stream[1] should be codec_type=subtitle codec_name=subrip
ffprobe -v error -show_entries stream=index,codec_type,codec_name /tmp/embedded-subs.mkv
```

### Run it

```bash
# 1. Build the CLI
swift build

# 2. Serve the file with the native subtitle rendition requested (parks; note the printed URL).
#    --native-subs N requests the native track; the engine now auto-attaches one cue store per
#    embedded text track inside start(), so the master advertises the SUBTITLES rendition.
.build/debug/aetherctl serve --native-subs 0 /tmp/embedded-subs.mkv
#    -> "=== PLAYBACK URL ===" prints e.g. http://127.0.0.1:58494/media.m3u8
#       The master is always at the same host:port, path /master.m3u8.

# 3. In another shell, point the harness at /master.m3u8 (NOT media.m3u8; the rendition lives
#    only in the master).
swift Tests/Integration/avplayer-open-check.swift http://127.0.0.1:<port>/master.m3u8 30

# 4. Ctrl-C the aetherctl process when done.
```

### Expected output (captured 2026-06-29, macOS 26.5, Xcode 26)

Against `/master.m3u8`:

```
[harness] opening http://127.0.0.1:58494/master.m3u8  (timeout 30s)
[harness] AVPlayerItem.status = .readyToPlay
[harness] legible media-selection options: 1
[harness]   [0] displayName="Subtitle 1" lang=nil mediaType=sbtl
[harness] PASS: readyToPlay + 1 legible option(s) against the loopback master
```

Negative control against `/media.m3u8` (no rendition in the media playlist) correctly reports
`legible media-selection options: 0` and exits 1.

Exit codes: `0` = readyToPlay AND >= 1 legible option; `1` = failed / timeout / no option;
`2` = bad usage. On `.failed` the harness dumps `AVPlayerItem.errorLog()` (status code, domain,
comment, URI) so an open failure names itself.

### Notes for on-device verification

- The served `.vtt` segments are header-only in the CLI path because the lazy embedded-subtitle
  readers that fill the cue stores are wired by the host (Sodalite), not by `aetherctl serve`.
  Exposure of the legible option does not need cues present (AVPlayer lists options from the
  master's `EXT-X-MEDIA` tags), so this harness validates open + exposure, not cue rendering.
  Cue rendering in the PiP window is verified by selecting the track in the host app.
- The CLI serves `media.m3u8` as the playback URL here because it defaults to `dvModeAvailable=true`
  (`effectiveDvMode` makes `sourceIsHDR` true, which keeps routing media-direct). On a real device
  with an SDR source the force-master path (#15, E6) serves the master directly. Either way the
  master endpoint exists and carries the rendition; the harness targets it explicitly.
- The one timing choice to verify on-device is the WebVTT cue alignment: segments use absolute
  media-timeline times + `X-TIMESTAMP-MAP=MPEGTS:0,LOCAL:00:00:00.000`. If PiP subtitles appear
  shifted by the segment start, flip `relativeToStart: true` at the single provider call site
  (`VideoSegmentProvider.nativeSubtitleVTT(ordinal:segmentIndex:)`); see `WebVTTBuilder.segment`.
