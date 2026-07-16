# Hybrid E-AC-3 JOC / Atmos tvOS device acceptance

## Status

Pending. Source-level routing and mux tests exist, but this gate is not passed until the exact
fixture and evidence below have been exercised on physical tvOS hardware. Simulator or macOS
AVPlayer results are not substitutes.

## Purpose

Validate the primary Hybrid carrier bandwidth policy with a real E-AC-3 JOC / Dolby Atmos
rendition. The loopback master must advertise `BANDWIDTH=2000000` without
`AVERAGE-BANDWIDTH`. The selected original Atmos rendition must remain stream-copy; observed
carrier peak and average bandwidth are privacy-safe diagnostics only and must never change the
audio pipeline, selected track, playback route, or declared transport budget.

## Fixture contract

Use a legally obtained, seekable VOD fixture with:

- a video packaging shape that deterministically selects `.hybridCarrierMetal` on tvOS;
- one original E-AC-3 JOC / Atmos audio rendition that FFmpeg identifies as E-AC-3 profile 30;
- at least one second selectable audio rendition so the AVKit audio-track switch can be tested;
- a duration long enough for startup, a forward seek, a backward seek, two track changes, and a
  controlled origin stall;
- recorded provenance, redistribution status, byte size, and SHA-256.

Keep non-redistributable media under `Fixtures/user/`; the directory is gitignored. Do not record
the fixture URL, signed query, cookies, headers, title, or track names in telemetry or committed
evidence. A synthetic E-AC-3 file with only `codecpar.profile = 30` is sufficient for unit routing
coverage, but it does not satisfy this device gate.

Before the device run, record a sanitized probe showing the selected rendition's codec, profile,
channel count, sample rate, duration, and stream ordinal. Confirm JOC / Atmos with a tool that can
inspect the real bitstream; container metadata alone is insufficient.

## Required device run

Record the Apple TV model, tvOS build, Xcode build, Aether commit, host-app commit, fixture SHA-256,
and UTC timestamp. Then perform one uninterrupted run:

1. Start the Hybrid session with the Atmos rendition selected. Confirm AVPlayer reaches playback,
   Metal presents real video, and audio is audible through an Atmos-capable output route.
2. Seek forward, then backward. Confirm the new generation presents real video and the original
   E-AC-3 JOC rendition remains selected and stream-copied.
3. Change to the second audio rendition through AVKit, then change back to Atmos. Confirm the
   active source track, carrier rendition, and analysis-track binding agree after each change.
4. Introduce a bounded origin stall after startup. Confirm the typed waiting/stall events identify
   the pressure and playback recovers without audio transcode, automatic track change, route
   switch, or runtime bandwidth measurement.
5. Stop and reopen the same item. Confirm no previous session, renderer generation, loopback
   server, or bandwidth observation leaks into the new session.

## Required assertions

- The served master contains `BANDWIDTH=2000000` and no `AVERAGE-BANDWIDTH`.
- The Atmos rendition reports `codec = ec-3`, `channels = 16/JOC`, and stream-copy throughout.
- Session telemetry reports `declaredTransportBudget = 2000000` plus observed emitted-carrier
  peak/average, segment count, rendition count, and `partial` / `complete` state.
- Carrier-bandwidth telemetry contains no source URL, path, header, credential, track identity,
  track name, codec string, or fixture identity.
- No full-asset measurement request occurs before provider construction or playback startup.
- No bandwidth observation triggers audio bridge/transcode, typed unsupported, track selection,
  route selection, or a change to the declared budget.
- Start, forward seek, backward seek, track switch in both directions, controlled stall recovery,
  stop, and reopen all pass on physical tvOS hardware.

If physical-device evidence shows that the fixed 2 Mbps declaration is insufficient, stop and
reopen the architecture policy decision. Do not add runtime measurement, automatic transcode,
automatic track selection, or route switching as a recovery.

## Evidence record

Store a sanitized Markdown or JSON record outside the fixture directory with these fields:

```text
status: pass | fail
appleTVModel:
tvOSBuild:
xcodeBuild:
aetherCommit:
hostCommit:
fixtureSHA256:
fixtureByteCount:
fixtureProvenanceReviewed: true | false
atmosBitstreamVerified: true | false
masterBandwidth: 2000000
masterAverageBandwidthPresent: false
observedPeakBandwidth:
observedAverageBandwidth:
observedSegmentCount:
start: pass | fail
forwardSeek: pass | fail
backwardSeek: pass | fail
trackSwitchAway: pass | fail
trackSwitchBackToAtmos: pass | fail
controlledStallRecovery: pass | fail
stopAndReopen: pass | fail
unexpectedTranscodeCount: 0
unexpectedTrackSwitchCount: 0
unexpectedRouteSwitchCount: 0
notes:
```

A missing field, unknown fixture hash, non-physical runtime, or absent structured event archive
keeps this gate pending.
