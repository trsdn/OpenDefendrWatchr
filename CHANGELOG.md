# Changelog

All notable changes to OpenDefendrWatchr will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
