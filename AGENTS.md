# AGENTS.md - OpenDefendrWatchr

This file is for AI agents. It describes the repo layout, conventions, and constraints so
changes stay small and correct.

## What This Is

A menu-bar-only macOS app (SwiftUI + SwiftPM, no Xcode project) that watches Microsoft
Defender's `wdavdaemon` for runaway memory growth, warns before the machine becomes
unusable, and logs the growth curve as evidence for an IT ticket. See `README.md` for the
incident that motivated it.

## File Layout

```
Package.swift                             # SwiftPM package (library + executable)
Sources/OpenDefendrWatchr/                # Library target: OpenDefendrWatchrKit
  App/WatchrApp.swift                     # MenuBarExtra scene, .accessory activation policy
  Model/MemorySample.swift                # Value types for one poll tick
  Model/Severity.swift                    # Severity, SeverityEvaluator, Thresholds
  Formatting/ByteFormatting.swift         # Deterministic compact/detailed byte strings
  Sampling/MemorySampling.swift           # Protocols + DefenderMemorySampler
  Sampling/ProcessMemoryReader.swift      # libproc enumeration, ps parsing, composite reader
  Sampling/HostSystemMemoryReader.swift   # host_statistics64 + hw.memsize
  Sampling/CommandRunner.swift            # CommandRunning protocol + Process implementation
  Monitoring/ThresholdMonitor.swift       # Debounce + hysteresis state machine
  Monitoring/WatchdogModel.swift          # @MainActor observable app state, poll loop
  Logging/SampleCSVLog.swift              # Rotating CSV log
  Notifications/AlertNotifier.swift       # UNUserNotificationCenter + alert wording
  Restart/DefenderRestartService.swift    # Manual, user-confirmed restart attempt
  Preferences/Preferences.swift           # UserDefaults + SMAppService launch-at-login
  UI/MenuBarContentView.swift             # Menu contents and confirmation dialogs
  UI/PreferencesView.swift                # Settings window
  Info.plist                              # LSUIElement=true, bundle id, __VERSION__ token
Sources/OpenDefendrWatchrApp/main.swift   # Executable entry point, --probe mode
Tests/OpenDefendrWatchrTests/             # Unit tests (XCTest)
scripts/build_swift_app.sh                # Assembles dist/OpenDefendrWatchr.app
.github/workflows/                        # validate-swift, secret-scan
Makefile                                  # build / run / probe / test / bundle / install / clean
README.md                                 # Human docs, incident write-up, limitations
CHANGELOG.md                              # Keep a Changelog + SemVer
```

## Hard Constraints

These are product decisions, not implementation details. Do not "improve" them away.

1. **Never restart Defender automatically.** Tamper protection is set to `block` on the
   target machine. Any restart must be manually triggered, must show a confirmation dialog
   that says the attempt will likely fail and may raise a tamper alert, and must report the
   real exit code, stdout and stderr rather than a generic result.
2. **No privileged helper.** No `SMJobBless`, no installed root daemon. Elevation is the
   one-shot AppleScript authorization prompt, plus a "copy the command" escape hatch.
3. **Never hardcode the page size.** Query it (`host_page_size`). It is 16384 on Apple
   silicon, 4096 on Intel.
4. **Never notify more than once per threshold crossing.** The debounce/hysteresis rules in
   `ThresholdMonitor` are the reason this app is usable; changes there need tests.
5. **Menu-bar-only.** `LSUIElement` in Info.plist plus `.accessory` activation policy in
   `AppDelegate` (the latter covers `swift run`, where no Info.plist is read). No Dock icon,
   no window at launch.
6. **"Not running" is a distinct state**, never `0 B`, in both the UI and the CSV log.
7. **Match the executable name exactly.** `wdavdaemon_enterprise` and
   `wdavdaemon_unprivileged` are different processes and must not be summed into the figure.

## Conventions

### Swift

- Swift language mode 5 for all targets (see `Package.swift`); `@MainActor` on UI-facing
  state (`WatchdogModel`).
- Sampling is injected behind `MemorySampling` / `ProcessMemoryReading` /
  `SystemMemoryReading` / `CommandRunning`. Tests must never depend on a live
  `wdavdaemon` or spawn real subprocesses.
- Keep formatting, parsing and state-machine logic in pure functions/structs so it can be
  tested directly. UI types stay thin.
- Comment only what needs explaining — kernel API quirks, ordering constraints, product
  decisions. Do not narrate obvious code.

### Known kernel API traps

- `proc_listallpids` returns a **PID count** on current macOS, despite the documented byte
  count. Treat it as a count and clamp to the buffer.
- `proc_pid_rusage` copies a full `rusage_info_v2` into the caller's buffer. Passing a bare
  pointer variable smashes the stack.
- Assigning to a `@Published` property inside its own `didSet` recurses. Clamp so the
  second pass is a no-op.

### Tests

- XCTest, in `Tests/OpenDefendrWatchrTests/`.
- Fixtures in `Fixture.swift` mirror the real incident (24 GB RAM, 16 KB pages,
  8491 free pages, 571,985 compressor pages, 18.91 GB process). Use them.
- Test behaviour that could plausibly break: hysteresis, severity escalation, `ps` parsing,
  byte formatting, CSV shape, threshold clamping. Do not add tests that assert trivialities.

### Configuration and secrets

- No API tokens, credentials, or personal absolute paths in the repo.
- Defaults must stay portable for a fresh clone.

## Build and Verify

```bash
make build && make test     # must both pass before committing
make probe                  # one live reading; sanity-check against `ps -Ao rss=,comm=`
make bundle                 # dist/OpenDefendrWatchr.app (local signature only)
```

`make bundle` fails loudly if `LSUIElement` is missing from the generated Info.plist.

## Releases

Notarised builds come from `trsdn/macos-notarization-broker`, not from here. Do not add a
local signing or notarisation path: the broker exists so Apple credentials never reach
source-repository code, and a second path would drift out of sync with the reviewed
profile.

Changing the bundle identifier, executable name, `Info.plist` layout, minimum macOS
version or entitlements breaks the broker profile `opendefendrwatchr` and requires a
reviewed change there first.

## Git

- Personal account identity: `trsdn` / `torsten.mahr@gmail.com`.
- Remote: `git@github-personal:trsdn/OpenDefendrWatchr.git` (public). Use the SSH
  host alias, not HTTPS, so the personal key is used.
- Logical, scoped commits (Conventional Commits style).
