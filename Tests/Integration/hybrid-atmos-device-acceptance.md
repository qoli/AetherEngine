# Hybrid E-AC-3 JOC / Atmos tvOS device acceptance

## Status

Technical physical-device rows and the final living-room downstream Atmos indicator pass. The exact JOC
fixture passes startup, forward/backward seek, bidirectional JOC/AAC selection, controlled stall recovery,
stop/reopen and privacy-safe bandwidth telemetry on the study Apple TV. A later Remote-driven physical
XCUITest also proves both renditions are available through AVKit's native Audio panel and that JOC → AAC
→ JOC updates AVKit's selected state. On the designated living-room Apple TV and LG C3 output chain, the
first human observation reported no Atmos activation; after the acceptance app was rebuilt, reinstalled
and relaunched with the same dual-rendition fixture and production carrier policy, the observer confirmed
normal Dolby Atmos activation. That later result is the final downstream-indicator outcome, while the
same uninterrupted human observation also confirms the complete JOC → AAC → JOC output transition:
the second rendition did not present as Atmos, and returning to the first rendition restored Atmos.
Technical selection state, simulator or macOS AVPlayer results are not substitutes. See
[`hybrid-display-device-evidence-2026-07-17.md`](hybrid-display-device-evidence-2026-07-17.md) and
[`hybrid-avkit-media-selection-ui-device-evidence-2026-07-18.md`](hybrid-avkit-media-selection-ui-device-evidence-2026-07-18.md).

### Retired loopback request regression closure — 2026-07-18

The Remote-driven UI build exposed a seek race while preparing the final human audio row. After a
forward seek moved the HLS pump to generation 1 / carrier segment 5, an already-issued AVPlayer
loopback request for segment 4 arrived late. The replacement generation was healthy, but the provider
incorrectly promoted that retired URI request to terminal
`requestedSegmentUnavailable(4)`. Formal runs failed closed with `providerFailed`; no route, player,
renderer, codec, or audio rendition fallback started.

Aether `bc488a0` classifies only this exact `target < generationStart` condition as a typed
`retiredSegmentRequest`. The individual stale loopback request remains unavailable, while the provider
stays healthy and serves the replacement generation. A current-generation production failure remains
terminal. A three-segment source test proves that startup segment 0 can be followed by a restart at
segment 2, a late unavailable segment 1 request, and successful segment 2 production without recording
a provider terminal error.

The corrected formal run used the study Apple TV and the same exact JOC graph:

```text
deviceName: 書房電視
device: physical Apple TV 4K (AppleTV6,2)
tvOS: 26.5 (23L471)
CoreDeviceID: 4F403AE1-B129-5248-BC6E-31DFDD75B422
AetherRevision: bc488a0
fixtureGraphIdentitySHA256: 5c2880748e03d2d59b621be4f69bc11f08c31331903e79b1d63ed30bc606dcf2
launcherSHA256: 144ecfa499b5b485766103a0ba14ff76a81cafbeed8a7a7177579313774f2b75
debugDylibSHA256: 15414653ed48ecd60bbbb00113bc70dc871228af0104a69e462403e07b122135
preflightRoute: hybridCarrier
preflightReason: hybridHLSManifestMissingCodecs
carrierBudget: 2000000
forwardSeek: pass, generation 0 -> 1
backwardSeek: pass, generation 1 -> 2
JOCToAAC: pass, generation 2 -> 3
AACToJOC: pass, generation 3 -> 4
audioTrackSwitchCheckpoint: pass
stopAndReopenCheckpoint: pass, new generation 0
renderer: rendering
carrierTimebaseBound: true
fallbackRouteCount: 0
```

The focused `HLSVODMediaPumpTests` suite passed 26 tests, and the full package run passed 738 tests in
130 suites. The app remains on the original JOC rendition after reopen for the still-pending human
audible-output and downstream Atmos-indicator observation.

### Human observation window fixture repair — 2026-07-18

Preparing the final human row exposed a fixture-generator defect rather than a playback defect. The
licensed JOC vector was shorter than `AETHER_ACCEPTANCE_DURATION_SECONDS`; FFmpeg therefore ended the
whole generated HLS graph when that input ended, despite the requested longer video and AAC alternate.
The prior 32-second graph was valid for automation but made a Remote-driven human Audio-panel check
unnecessarily time-limited.

Aether `e6a2111` makes the fixture policy explicit: the user-supplied licensed E-AC-3 JOC input is
packet-repeated to the requested video duration and remains stream-copy. It is never replaced by AAC,
transcoded, measured as a startup policy, or used to change route. `PROVENANCE.txt` records the repeat
policy without recording the source path or bytes. Playlist normalization still permits only the
bounded 90 kHz `EXTINF` serialization correction and requires equal video/JOC/AAC segment counts.

Two generated-fixture checks passed:

```text
generatorRevision: e6a2111
40SecondSmokeIdentitySHA256: 5102d6fb832501908c249493bee3c5730aa5e3d96d1d753990b7546abcf2e8f4
40SecondSmokeDuration: 40.000000
40SecondSmokeSegments: video=10, JOC=10, AAC=10
192SecondHumanIdentitySHA256: 99fe05586a520c64a22ececa6ef054d7c6a0635fc5f5e5f855577e329a2ec584
192SecondHumanDuration: 192.000000
192SecondHumanSegments: video=48, JOC=48, AAC=48
JOCProbe: codec=eac3, profile=Dolby Digital Plus + Dolby Atmos, channels=6
masterSignal: CHANNELS="16/JOC"
repeatPolicy: packet-level repeat; E-AC-3 JOC stream-copy
```

The 192-second graph also reached `.hybridCarrier` on the study Apple TV with 48 source segments, two
audible renditions, a bound carrier timebase, the single rendering display layer and carrier
`BANDWIDTH=2000000`. This extends only the observation window; the audible JOC/AAC distinction and
downstream television/AVR Atmos indicator remain human observations and are not marked passed here.

### Living-room deployment for final human Atmos row — 2026-07-18

The study-room Apple TV remains the source of the automated clock/seek/stall/selection evidence above,
but it does not have the required downstream Dolby Atmos observation conditions. The release owner
therefore designated the living-room Apple TV and its connected television/audio chain as the final
human audible-output and Atmos-indicator target. This is a device-gate correction, not a route or codec
policy change.

The exact Aether mini acceptance app was built, installed and launched on that device:

```text
deviceName: 客廳電視
device: physical Apple TV 4K (3rd generation, AppleTV14,1 / J255AP)
tvOS: 26.5 (23L471)
CoreDeviceID: 091555FF-9FE8-5A47-B90A-CBDDC737E052
XcodeDestinationID: 00008110-000C613A1142801E
AetherRevision: 01a2224
configuration: Debug; destination-specific signed device build
build: pass
install: pass
launcherSHA256: 56ffcf103acab5a203c6f69de940d8fff5f454f6fda3059c5e42954a9f51ea34
debugDylibSHA256: 6b96c4efc9649f8ef289e8f4cb8c5de38d8d81a0e48faaf9cd5beaa26b527c9b
fixtureIdentitySHA256: 99fe05586a520c64a22ececa6ef054d7c6a0635fc5f5e5f855577e329a2ec584
fixtureDuration: 192 seconds
preflightRoute: hybridCarrier
preflightReason: hybridHLSManifestMissingCodecs
sourceSegments: 48
audioRenditions: 2
carrierBudget: 2000000
selectedStartupRendition: E-AC-3 JOC stream-copy
carrierTimebaseBound: true
renderer: rendering
fallbackRouteCount: 0
humanJOCToAACAtmosTransition: pass — audio_2 did not present as Atmos
humanAACToJOCAtmosReturn: pass — audio_1 restored Atmos
downstreamAtmosIndicatorFirstObservation: fail — LG C3 did not activate Dolby Atmos
downstreamAtmosIndicatorFinalObservation: pass — LG C3 activated Dolby Atmos normally
audioSelectionGenerations: JOC generation 0 -> AAC generation 1 -> JOC generation 2
atmosDeviceGate: pass
```

The app deliberately exposes AVKit's native Audio panel and no competing custom transport controls.
The first human result was negative, but the final repeated observation is positive: the LG C3 activated
Dolby Atmos normally on the exact stream-copy JOC rendition. Both observations remain recorded because
the intervening rebuild/reinstall/relaunch means no root cause may be inferred from the recovery. During
the relaunched run, the observer then selected `audio_2`,
confirmed that output was no longer Atmos, and selected `audio_1`, which restored Atmos. The loopback
requests and provider generations independently recorded JOC generation 0 → AAC generation 1 → JOC
generation 2. This closes the human Atmos round trip without adding audio transcode, automatic track
selection, route switching or another runtime fallback.

### End-of-stream presentation incident follow-up — 2026-07-18

The first 192-second living-room observation run exposed an independent long-play failure after all 48
carrier segments had completed. At carrier time approximately 185.557 seconds, the sample-buffer
presentation path failed closed with `AVFoundationErrorDomain(-11847): Operation Interrupted`, surfaced
as typed `presentationFailed`. No fallback route, player, renderer or audio pipeline started. This does
not negate the successful Atmos and bidirectional audio-selection evidence.

Aether `c61dae6` adds privacy-safe failure-boundary fields for renderer status, flush requirement,
generation, queue counts, carrier time/duration and last accepted/enqueued video time. It also adds two
acceptance-only EOS modes: a generation-0 baseline and a generation-4 run after two JOC/AAC round trips.
Neither mode changes the player, route, renderer or failure policy.

Three controlled follow-up runs on the designated study Apple TV did not reproduce the incident:

```text
deviceName: 書房電視
device: physical Apple TV 4K (AppleTV6,2)
tvOS: 26.5 (23L471)
CoreDeviceID: 4F403AE1-B129-5248-BC6E-31DFDD75B422
AetherRevision: c61dae6
24SecondGeneration0: pass — sessionEnded=24.056883, renderer=rendering
24SecondGeneration4: pass — sessionEnded=24.056847, renderer=rendering
192SecondGeneration4: pass — sessionEnded=192.039728, renderer=rendering
192SecondCarrierSegments: 48/48 complete
192SecondEnqueuedSampleBuffers: 4640
192SecondPendingSampleBuffersAtEnd: 0
fallbackRouteCount: 0
swiftTest: 738 tests / 130 suites pass
```

The incident is therefore classified as a non-reproduced single observation rather than a fixed defect.
No special-case `-11847` suppression, flush/retry, renderer replacement or other runtime fallback was
added. The exact-length generation-4 rerun closes this EOS follow-up for Gate 1A while retaining the new
diagnostics for any recurrence.

### Licensed JOC carrier-integrity diagnostic — 2026-07-18

The initial negative observation exposed a real automated-evidence gap: the earlier JOC unit test set
`codecpar.profile = 30` on a synthetic E-AC-3 stream and therefore proved routing and master metadata,
but not that a licensed JOC access unit survived the carrier remux. Aether `01a2224` adds a private-fixture
integration diagnostic that skips unless the caller explicitly supplies the licensed fixture URL and
local directory. It prints no URL, path or compressed bytes.

The exact 192-second fixture produced this result:

```text
sourceProfile: 30
carrierProfile: 30
accessUnitsCompared: 125
compressedBytesCompared: 224000
compressedPayloadIdentity: true
sourceDEC3Bytes: 15
carrierDEC3Bytes: 15
dec3Identity: true
carrierSampleEntry: ec-3
```

This bounds the carrier remux: its first output fragment retains the source JOC compressed payload and
the same `EC3SpecificBox`. It does not prove the HDMI/eARC render by itself. The acceptance app also
records `AVAudioSession.renderingMode` without activating or reconfiguring the session; Apple documents
that property as `notApplicable` on HDMI, so it is diagnostic only and never overrides the LG C3 human
indicator.

## Purpose

Validate the primary Hybrid carrier bandwidth policy with a real E-AC-3 JOC / Dolby Atmos
rendition. The loopback master must advertise `BANDWIDTH=2000000` without
`AVERAGE-BANDWIDTH`. The selected original Atmos rendition must remain stream-copy; observed
carrier peak and average bandwidth are privacy-safe diagnostics only and must never change the
audio pipeline, selected track, playback route, or declared transport budget.

## Fixture contract

Use a legally obtained, seekable VOD fixture with:

- a video packaging shape that deterministically selects `.hybridCarrier` on tvOS;
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
   sample-buffer presentation shows real video, and audio is audible through an Atmos-capable output route.
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
