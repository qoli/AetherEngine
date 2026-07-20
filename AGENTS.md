# AetherEngine Agent Execution Guide

## Recovery-first policy

AetherEngine is a media player. Recovering useful playback from transient,
platform, transport, decoder, packaging, and presentation failures is a core
product responsibility, not an exception to it.

This repository has previously applied no-fallback reasoning too broadly and has
lost valid player resilience as a result. Do not use "explicit failure" or route
purity as a reason to remove, refuse, or fail to design a safe recovery path.
Preserve and restore playback tolerance when the media can still be played
correctly by an Aether-owned route.

The forbidden behavior is **hidden semantic substitution**: silently changing the
requested media identity, origin, credentials, DRM meaning, user-selected track,
or producing valid-looking output from guessed data. A bounded and observable
retry, reopen, item rebuild, decoder change, playlist change, or Aether-owned
backend change that preserves the playback request is recovery, not forbidden
fallback.

A recovery that satisfies this guide is authorized by repository policy and does
not require per-change approval merely because it switches an implementation.
Ask for approval only when the proposal changes media identity/provenance, bypasses
security or DRM, invents semantic data, or introduces an unbounded or hidden
degradation.

The latest user scope remains authoritative. Keep each fix narrow to the actual
failure path, but do not stop at a fail-closed state while a safe in-engine
recovery remains available.

## Product priorities

Apply these priorities in order:

1. Preserve media correctness, source identity, authorization, and DRM/security
   boundaries.
2. Keep or restore continuous playback when an Aether-owned recovery can do so.
3. Preserve position, timeline, track choices, rate, play/pause intent, subtitles,
   audio-analysis identity, HDR/Atmos behavior, PiP, and external playback.
4. Surface any unavoidable capability reduction explicitly.
5. Emit a terminal error only after the admissible recovery budget is exhausted
   or the failure is genuinely non-recoverable.
6. Prefer architectural simplicity only after the user-visible playback contract
   is satisfied.

Do not optimize for a pure route graph at the expense of a playable movie.

## Existing capability first

Before adding a demuxer, seek path, restart mechanism, codec-parameter repair,
or recovery implementation, first establish why the existing `AetherEngine`,
`HLSVideoEngine`, `NativeAVPlayerHost`, or `SoftwarePlaybackHost` capability
cannot satisfy the request. The unified playback session is an ownership and
lifecycle adapter; it must not narrow the success semantics of those engines or
replace a mature path with a less resilient parallel implementation.

When a new route bypasses an existing capability and loses resilience, restore
capability routing to the original owner before modifying the newer media
pipeline.

Keep these two capabilities distinct:

- AetherEngine producing loopback HLS-fMP4 is an established remux output used
  for progressive containers such as Matroska that AVPlayer cannot ingest.
- Feeding a remote HLS playlist into FFmpeg's HLS demuxer and producing another
  HLS playlist is a new HLS-in-HLS-out capability. It must be designed and
  accepted independently; do not describe it as reconnecting existing remux
  capability.

Clear H.264/AAC remote HLS is direct AVPlayer media after positive segment
inspection confirms an AVPlayer-supported MPEG-TS or fMP4 stream. Direct media
playlists may legitimately omit `CODECS`; missing or stale manifest `CODECS`
does not authorize REMUX or Hybrid. Hybrid is reserved for a codec AVPlayer
cannot decode, not for incomplete manifest metadata or AVPlayer-incompatible
packaging of an otherwise native codec.

The unified session adapter may delegate lifecycle operations, observe the
engine's state and seek/recovery intent, manage operation supersession, and
enforce an overall deadline. It must not implement segment production, cache
epochs, producer restart, decoder bootstrap, or a second seek algorithm. Do not
judge seek failure from an immediate `currentTime` tolerance, and do not treat a
`playing` flag without demonstrated media-time progress as successful recovery.

## Read the controlling path first

Inspect the real owner before changing behavior:

- `Sources/AetherEngine/AetherEngine.swift`: public load, source probe, initial
  audio/video dispatch, state, and lifecycle ownership.
- `Sources/AetherEngine/AetherEngine+Loading.swift`: native/software/audio host
  construction, reload, stall recovery, item revive, master/media recovery, and
  state continuity.
- `Sources/AetherEngine/PlayerState.swift`: public states, `PlaybackPhase`, load
  options, and published capability semantics.
- `Sources/AetherEngine/Native/NativeAVPlayerHost.swift`: AVPlayer item lifecycle,
  deferred failures, display rejection, and in-place reload behavior.
- `Sources/AetherEngine/Native/StartupReadinessGate.swift`,
  `MasterFallbackDecision.swift`, and `Issue93ItemDeathRevive.swift`: existing
  bounded native recovery decisions.
- `Sources/AetherEngine/Hybrid/PlaybackPreflight.swift` and
  `AetherPlaybackSessionFactory.swift`: source classification, preflight route,
  typed unsupported results, and the launch boundary.
- `Sources/AetherEngine/Hybrid/AetherHybridPlaybackSession.swift` and related
  carrier/provider files: black-carrier timebase, direct decode, sample-buffer
  presentation, subtitles, and audio analysis.
- `Sources/AetherEngine/Video/HLSVideoEngine*.swift`, `RestartCoalescer.swift`,
  `Issue65LivelockBreakers.swift`, and `Issue99MuxerFailureRevive.swift`: segment
  production, live reopen, seek/restart coalescing, wedge recovery, and muxer
  rebuild.
- `Sources/AetherEngine/Decoder`: hardware/software capability and decode policy.
- `Sources/AetherEngine/Demuxer`, `Sources/AetherEngine/IO`, and
  `Sources/AetherEngine/Network`: open/read/reconnect, custom IO, HLS ingest, and
  loopback transport.
- `Sources/AetherEngine/Subtitles` and `Sources/AetherEngine/Audio/Analysis`:
  optional or independently failing capabilities that must not unnecessarily
  terminate core playback.
- `Sources/AetherEngine/Diagnostics`: `EngineLog`, FFmpeg diagnostics, telemetry,
  and correlation surfaces.
- `Tests/AetherEngineTests`: recovery gates and regression coverage. Existing test
  names that say "fails instead of trying another route" document current
  behavior; they do not make that behavior permanent product policy.

Use `README.md`, `docs/architecture.md`, and `docs/formats.md` for declared
capabilities, then verify current code, tests, device evidence, and the latest user
decision. Documentation and old tests may preserve an over-strict no-fallback
decision and must be reassessed when the task concerns lost resilience.

## Required vocabulary

Use these categories instead of calling every alternate path "fallback":

1. **Capability routing** selects native, software, audio-only, remote-HLS, or
   Hybrid before presentation from known source/platform facts.
2. **Adaptation** changes bitrate, buffering, segment window, clock correction,
   track, presentation mode, or live-edge behavior within an active route.
3. **Recovery** responds to a failure by retrying, reopening, rebuilding, changing
   playlist/variant, changing decoder, or changing Aether-owned route while
   preserving the same playback request.
4. **Graceful degradation** keeps core playback but loses a nonessential or
   unsupported capability, with a typed/publicly observable capability delta.
5. **Hidden semantic substitution** changes source identity, provenance, auth,
   DRM, user intent, or invents data without a contract. This remains forbidden.
6. **Terminal failure** is the final outcome only after safe recovery is
   inapplicable or exhausted.

`try?`, `catch`, `??`, retry, reopen, fallback, alternate, and default are review
signals, not automatic violations. Classify the semantic effect before judging
the syntax.

## Recovery contract

AetherEngine recovery must satisfy the following minimum contract:

- Keep the same canonical `MediaSource`, URL/custom reader identity, HTTP headers,
  authorization, selected title, and content provenance.
- Use a typed or evidence-backed trigger. Distinguish transient network loss,
  display rejection, decoder failure, item death, no-progress stall, muxer death,
  cancellation, EOF, unsupported media, and corrupt input.
- Bound retries, elapsed time, rebuilds, and route transitions. Reset a budget only
  after demonstrated progress or a new user action, not merely after a delay.
- Preserve the first error and the recovery history for diagnostics even when a
  later attempt succeeds.
- Preserve playback position/timeline and user intent. For live playback, preserve
  the correct live-edge/rejoin contract rather than applying VOD resume rules.
- Restore track, subtitle, rate, volume, play/pause, metadata, audio-analysis, PiP,
  external playback, and display state where the destination route supports them.
- Publish recovery phase and outcome. `PlaybackPhase`, telemetry, or a typed event
  must distinguish recovering/reconnecting from ordinary buffering and terminal
  error.
- Surface unavoidable capability loss, such as HDR/Dolby Vision/Atmos, native
  subtitles, DVR, PiP, or analysis availability. Do not hide it in logs alone.
- Emit one terminal outcome when all recovery ends. Never emit success or `.ended`
  for a failed open, probe, decode, or presentation attempt.

Recovery does not need to preserve the same implementation. It needs to preserve
the same truthful playback request and explicitly account for any capability
change.

## Preferred recovery ladder

Choose the least disruptive action supported by evidence, then escalate. The
exact ladder is failure-specific, but normally consider:

1. Wait through a known platform settle window or retry the failed operation.
2. Reconnect/reopen the same source with bounded backoff.
3. Re-anchor, flush, nudge, or rebuild the failed producer/decoder/item while
   keeping the route.
4. Switch to a truthful alternate playlist/variant or packaging representation of
   the same source.
5. Switch hardware/software decoder or Aether-owned playback backend.
6. Continue with an explicitly unavailable optional capability.
7. Surface terminal failure with the original cause and attempted recovery path.

Do not mechanically perform every stage. Skip stages that cannot address the
observed failure, violate source semantics, repeat a known permanent error, or
would degrade a required capability without an admitted contract.

## AetherEngine-specific policy

- AetherEngine, not Syncnext or another host, owns source classification, route
  recovery, carrier, decode, presentation, subtitles, diagnostics, and audio
  analysis. Hosts may render state and user choices; they must not guess a second
  engine/source after an opaque Aether failure.
- A preflight route is the initial evidence-backed route, not automatically an
  irrevocable lifetime sentence. A later engine-owned route recovery is allowed
  when runtime evidence invalidates the initial assumption and the recovery
  contract is satisfied.
- `.unsupported` is correct for a proven capability/security boundary. It is not
  the default for incomplete inspection, uncertain packaging, a transient probe,
  an AVPlayer-specific failure, or a route that has not tried another safe
  Aether-owned implementation.
- Do not preserve a fail-closed branch merely because an existing test asserts
  `.unsupported`, "fails instead of entering Hybrid", or "must not try another
  route". If the task is about lost playability, reassess the admissible route
  matrix and update the test to the intended recovery contract.
- Hybrid real-video presentation remains Aether-owned through
  `AVSampleBufferDisplayLayer` with the carrier `AVPlayerItem.timebase`. Recovery
  must not reintroduce MTKView or a split Hybrid renderer. This does not prohibit
  an engine-owned session/backend recovery outside the Hybrid renderer itself.
- Preserve existing bounded recovery such as startup readiness, master-to-media
  recovery, display-rejection handling, spurious-pause reassertion, stalled-item
  reload, item-death revive, live reopen, restart coalescing, backpressure wedge
  recovery, recovery seek targeting, and muxer rebuild. Do not delete these paths
  simply because their comments use "fallback" or "revive".
- URL probe failure may be recoverable by reopening the same URL in the selected
  playback path. Custom-reader probe failure is different when no independent
  reopen exists. Treat these source contracts separately.
- Authentication/authorization failure, unsupported encryption/DRM, invalid
  source identity, cancellation, and positively corrupt media must not trigger a
  blind route storm. They may still use a narrowly justified same-source retry if
  the error is known to be transient.
- EOF after real playback is completion. EOF before a playable stream or frame is
  established is not successful empty playback.
- An invalid saved track/title selection should not silently change content
  semantics. Retaining an explicit automatic-selection contract is acceptable,
  but the resolved selection must be published so the host knows what played.
- Subtitle rendering, native subtitle renditions, audio analysis, thumbnailing,
  metadata decoration, DVR retention, and similar auxiliary capabilities may fail
  independently. Keep core playback when safe, publish typed unavailability, and
  preserve the user's selection for a later reload/recovery when appropriate.
- Do not change dependency pins, fixture provenance, transport, source URL,
  credentials, or global test overrides to make a recovery test pass.

## Diagnosing lost resilience

For a playback failure, start from the actual source shape, options, platform,
display/audio route, selected backend, first error, last demonstrated progress,
and recovery events. Do not infer the owner from the final host message.

Before changing code, answer:

- What exact failure occurred, and at which open/probe/demux/decode/mux/render
  stage?
- Was playback ever demonstrably healthy?
- Is the error permanent, transient, cancellation, EOF, capability mismatch, or
  still unknown?
- Which existing recovery budget ran, and why did it stop or false-positive?
- Did no-fallback reasoning prematurely turn a recoverable state into
  `.unsupported` or `.error`?
- What is the least disruptive Aether-owned recovery that preserves the request?
- Which capability may be lost, and how will the host/user observe that loss?

For unclear stalls or device-only behavior, increase observability before changing
the route. Prefer pure decision gates plus device-facing telemetry over timing
guesses spread through session code.

## Error and telemetry rules

- Preserve raw AVFoundation/CoreMedia/VideoToolbox/FFmpeg/URLSession errors and
  codes. Add diagnosis; do not replace the cause with a friendly string.
- Correlate load/session, source, route, item, producer, decoder, seek/restart,
  attempt, and terminal outcome.
- Log progress evidence that resets recovery budgets: rendered clock advance,
  segment fetches, decoded frames, live-edge movement, or user seek.
- A first-attempt error is diagnostic while recovery is active, not a terminal
  public error.
- Cancellation or a superseded generation belongs to the successor operation and
  must not overwrite its state with an error.
- Never log authorization headers, cookies, tokens, complete signed URLs, SMB
  credentials, or media payloads. Retain redacted host/path class, stage, timing,
  and error code.

## Implementation workflow

1. Reproduce or bound the failure on the real backend and platform surface.
2. Write invariants: source identity, position/timeline, user intent, required and
   optional capabilities, and recovery budget.
3. Locate the controlling Aether layer. Fix engine behavior in AetherEngine rather
   than adding host compensation.
4. Classify the change as routing, adaptation, recovery, degradation, hidden
   substitution, or terminal failure.
5. Add or refine a pure decision gate when timing/error classification is subtle.
6. Implement the smallest recovery that addresses the observed failure, including
   budget exhaustion and teardown/cancellation behavior.
7. Add deterministic unit tests for decisions and state continuity, then use the
   exact fixture/device route needed for platform validation.
8. Update declared capability/limitation documentation and `CHANGELOG.md` when a
   user-visible playback contract changes.

## Required tests for recovery work

Cover the applicable cases:

- primary success without entering recovery;
- exact recoverable trigger and successful recovery;
- slow-but-progressing playback that must not false-trigger;
- real pause/background/cancellation that must not be fought;
- retry/reopen/rebuild/route budget exhaustion;
- progress or a new user action correctly resetting an episode budget;
- first-error and recovery-history preservation;
- same source, headers, selected title/track, and provenance across recovery;
- VOD position and live rejoin/live-edge continuity;
- subtitle/audio-analysis/metadata/PiP/external-playback state restoration;
- explicit capability delta when the recovered path cannot preserve a feature;
- second-path failure produces one terminal error and no valid-looking output;
- no recovery storm for permanent/auth/DRM/corrupt-input errors;
- no secrets in logs or telemetry.

Use isolated test fakes only in test targets. Do not add placeholder frames, mock
media, synthetic success, or alternate production sources.

Run the narrow test first, then the repository verification surface:

```bash
rtk swift test --filter <RelevantTestOrSuite>
rtk swift build
rtk swift test
rtk xcodebuild build \
  -scheme AetherEngine \
  -destination 'generic/platform=tvOS Simulator' \
  -derivedDataPath .build/xcode-tvos \
  CODE_SIGNING_ALLOWED=NO
rtk xcodebuild build \
  -scheme AetherEngine \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/xcode-ios \
  CODE_SIGNING_ALLOWED=NO
```

Rendering, HDR/Dolby Vision, Atmos, PiP, HDMI/display switching, and some AVPlayer
recovery behavior require the exact physical device/OS/display/audio route and
media fixture. Simulator or macOS unit success is not proof of those contracts.

## Completion report

Every playback-resilience change must report:

- hidden semantic fallback added: yes/no;
- recovery added, removed, or changed: exact trigger and path;
- why the failure is recoverable or terminal;
- attempt/time/transition budgets and reset condition;
- source, timeline, intent, and capability state preserved;
- capability degradation and its public signal;
- first/original error and terminal error behavior;
- tests and device/fixture verification performed;
- exact unverified surfaces or blockers.
