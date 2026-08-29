# Changelog

All notable changes to OpenDefendrWatchr will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `--login-item [enable|disable|status]`, which registers, unregisters and — most
  importantly — *reports* the launch-at-login state from the command line. The app was
  previously only ever started by hand, so a reboot silently ended monitoring and nothing
  said so for 30 hours. Registration that cannot be read back is indistinguishable from
  registration that failed.
- `LaunchAtLoginStatus`, which keeps `requiresApproval` distinct from `notRegistered` and
  `notFound`. Collapsing them into a single "off" would hide the only one of the three the
  user can act on.
- `StallProbe`, which times `open()`/`close()` cycles to measure how long trivial
  filesystem work is taking. Every `open()` is authorised by the kernel's Endpoint Security
  layer, so this latency is a direct measurement of an ES client stalling. Surfaced in the
  menu, in `--probe`, and as a new `stall_us` CSV column.
- `AlertCause.systemStall`, with wording that names Endpoint Security and states plainly
  that memory is not the fault, so the user does not spend the incident checking the wrong
  thing.
- Memory pressure derived from `kern.memorystatus_level`, as an `available_pct` and
  `pressure_level` CSV column and a menu line. Warning at 20% available, critical at 10%.
- `kernel_pressure_raw` CSV column recording `kern.memorystatus_vm_pressure_level` as
  context. It is deliberately *not* used for alarm: measured on a healthy machine it
  latched at `warning` for minutes while 46% of memory was available, so driving alerts
  from it would park the app in a permanent warning state.

### Changed

- Severity is now the worst of three independent verdicts — the watched process, kernel
  memory pressure, and filesystem stall — instead of being anchored to the watched process.
  A machine can be dying while `wdavdaemon` is innocent, and previously the app reported
  `normal` throughout exactly that situation.
- Threshold re-arming requires *every* driver to recede, not just the byte figure. Under a
  system-driven alert the watched process is small, which would otherwise satisfy the byte
  rule on every tick and turn one incident into a notification storm.

### Removed

- The `free < 5% AND compressed > 30%` starvation heuristic. Measured against a real
  1260-sample log it held in 99.3% of samples taken during entirely normal operation: macOS
  deliberately keeps the free list near-empty, so raw free pages carry no information about
  danger.

## [0.2.1] - 2026-08-22

### Fixed

- Lower the SwiftPM manifest to tools version 6.1. The signing broker's runner ships Swift
  6.1, so a 6.2 manifest failed to build there and no release could be notarised.

## [0.2.0] - 2026-08-22

### Added

- "Send Test Notification" menu item and a `--notify-test` CLI flag, so alert delivery can
  be verified before an incident rather than during one. The test carries the current live
  reading, and never counts as a threshold crossing.
- `NotificationDeliveryStatus`, reporting the real delivery outcome. A refused or
  unavailable notification is surfaced with the System Settings location to fix it, instead
  of failing silently.
- Release notarisation via `trsdn/macos-notarization-broker` (profile
  `opendefendrwatchr`), which builds from a pinned tag and signs in an isolated job so
  Apple credentials never reach this repository. There is deliberately no local signing
  path.
- MIT `LICENSE`, and CI under `.github/workflows`: `validate-swift` (debug and release
  build, tests, unsigned bundle assembly, and a check that `LSUIElement` survives into
  `Info.plist`) and `secret-scan`.

## [0.1.0] - 2026-08-22

Initial release, written in response to the 2026-08-22 `wdavdaemon` memory incident
(18.91 GB resident, ~139 MB free, machine unusable, forced restart).

### Added

- Menu bar item showing `wdavdaemon` resident memory compactly (e.g. `18.9G`), with a
  shield glyph that changes shape by severity so it stays legible in light and dark
  menu bars.
- Polling of `wdavdaemon` resident memory on a configurable interval (default 30s),
  using `libproc` for process discovery and falling back to `ps` only for the RSS of
  root-owned processes.
- System memory pressure tracking via `host_statistics64` with a queried page size,
  so a large process is only escalated to critical when the machine is actually starving.
- Configurable warning (default 8 GB) and critical (default 12 GB) thresholds,
  persisted in `UserDefaults`.
- User notifications on threshold crossings, with confirmation debounce and hysteresis
  so each crossing notifies exactly once and re-arms only after a meaningful drop.
- Rotating CSV log of the growth curve under
  `~/Library/Application Support/OpenDefendrWatchr/`, with a menu item to reveal it in Finder.
- Manual "Try Restart Defender…" menu item that warns about tamper protection, requires
  explicit confirmation, and reports the real exit code, stdout and stderr.
- "Copy Restart Command" menu item for running the `launchctl kickstart` by hand.
- Preferences window for poll interval, thresholds and launch-at-login (`SMAppService`).
- `--probe` command line mode that prints one reading and exits, for verification and
  for pasting into support tickets.
