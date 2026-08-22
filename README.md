# OpenDefendrWatchr

A tiny macOS menu bar app that watches Microsoft Defender's `wdavdaemon` process for
runaway memory growth and warns you **before** the machine dies.

## Why this exists

On 2026-08-22 a Mac mini M4 Pro (`Mac16,11`, 24 GB RAM, macOS 26.6.2) became unusable.
The system logs tell the whole story:

- `JetsamEvent-2026-08-22-064004.ips` fired at 06:40. At that instant free memory was
  **8491 pages of 16 KB (~139 MB)**, the compressor held **571,985 pages (~9.4 GB)**, and
  the single largest process was **`wdavdaemon` at 18.91 GB resident** (1,154,000+ `rpages`).
  The runners-up were trivial by comparison: Teams WebView Helper at 1.41 GB and
  WindowServer at 1.13 GB.
- Immediately afterwards `bluetoothd` began crashing with `EXC_CRASH`/`SIGABRT` every
  3–20 minutes — 24 crash reports between 06:50 and 09:49, collateral damage from memory
  starvation.
- The machine was force-restarted at 09:53. There is **no kernel panic report**: this was
  memory starvation and unresponsiveness, not a panic.

The goal is not to fix Defender. The goal is to never be surprised again: warn early
enough to save work and reboot deliberately, and collect hard evidence for an IT ticket.

## What it does

- Polls `wdavdaemon` resident memory on a configurable interval (default 30s).
- Tracks real system memory pressure (free pages + compressor) alongside it, so a big
  process is only called *critical* when the machine is genuinely starving.
- Shows the current figure compactly in the menu bar (`18.9G`) with a shield glyph whose
  **shape** changes with severity — normal / warning / critical — so it stays legible in
  both light and dark menu bars.
- Notifies **once** per threshold crossing, with debounce and hysteresis. It re-arms only
  after usage drops meaningfully back below the threshold.
- Appends every sample to a rotating CSV log — the evidence for the ticket.
- Handles "Defender isn't running" as its own state (`—`) instead of pretending it is 0 B.

### Thresholds

| Level | Default | Meaning |
|---|---|---|
| Warning | 8 GB | `wdavdaemon` is far past normal (~100 MB) and worth watching. |
| Critical | 12 GB | Save your work; consider a deliberate reboot. |

Both are editable in Preferences and persisted. A warning-level process is escalated to
critical when free RAM drops below 5% *and* the compressor exceeds 30% of RAM — the
combination that preceded the jetsam event.

## The tamper protection limitation (read this)

On the affected machine:

```
mdatp health --field tamper_protection        → "block"
mdatp health --field real_time_protection_enabled → true
Defender product version                      → 101.26072.0015
```

With tamper protection in `block` mode, **Defender actively prevents its own processes
from being stopped, killed or unloaded.** Therefore:

- **OpenDefendrWatchr never restarts Defender automatically.** Automatic restart is out of
  scope by design. An unattended app fighting a security product is a bad idea and would
  generate tamper alerts.
- There is a **manual** "Try Restart Defender…" menu item. It shows a confirmation dialog
  that plainly states the attempt will most likely **fail**, and may raise a tamper alert
  with your IT/security team. It only proceeds on explicit confirmation.
- The attempt runs:

  ```
  sudo launchctl kickstart -k system/com.microsoft.fresno
  ```

  (`com.microsoft.fresno` is the Defender daemon's launchd label.)
- The exit code, stdout and stderr are captured, logged and shown to you verbatim. You get
  the actual result, not a generic "success"/"failure" — that raw output is what an IT
  ticket needs.

### Why no privileged helper

Elevation goes through AppleScript's standard authorization prompt
(`do shell script … with administrator privileges`), not `SMJobBless` and not an installed
root helper. Reasons:

- A one-shot, user-initiated command does not justify a permanently installed root
  component — that would be a larger attack surface than the problem it solves.
- A privileged helper would also have to be signed, versioned and updated, all so it can
  run a command that is expected to fail anyway.
- "Copy Restart Command" is offered alongside it, so you can paste the command into
  Terminal yourself and see the unmediated output. That is often the better move when you
  are already writing a ticket.

## Requirements

- macOS 14 or later (built and verified on macOS 26.6.2, Apple silicon)
- Swift 6.2 toolchain (Xcode command line tools)

## Build and install

```bash
make build      # debug build
make test       # unit tests
make bundle     # dist/OpenDefendrWatchr.app
make install    # install to /Applications and launch
make probe      # print one live reading and exit
```

`make run` runs it straight from SwiftPM. Two features need a real installed `.app` and are
disabled otherwise: user notifications (no bundle identity) and launch-at-login
(`SMAppService`).

### Release builds and notarisation

`make bundle` signs with whatever certificate is on the build machine, which is fine
locally but rejected by Gatekeeper anywhere else. Signed releases are **not** produced
here.

Notarised builds come from [`trsdn/macos-notarization-broker`](https://github.com/trsdn/macos-notarization-broker),
which builds from a pinned tag and signs in an isolated job, so Apple credentials are never
exposed to this repository's code. Deliberately, there is no local signing path to drift
out of sync with it.

```bash
# in a checkout of the broker
scripts/request.sh opendefendrwatchr vX.Y.Z
```

The broker owns the build adapter and the entitlements policy. A release that changes the
bundle identifier, executable, layout, architecture, entitlements or minimum macOS version
requires a reviewed profile update there — including the check that `LSUIElement` is still
set, so the app cannot silently regain a Dock icon.

`make probe` is also the quickest sanity check:

```
$ make probe
wdavdaemon: 85.69 MB (86M) across 1 process(es), pids [557]
system: free 1.45 GB (6.1%), compressed 8.57 GB, total 24.00 GB, page size 16384
severity: Normal
```

## Verifying that alerts actually arrive

A watchdog that cannot reach you is worse than no watchdog, because you will trust it. So
the notification path is testable on demand rather than only during an incident: use
**"Send Test Notification"** in the menu, or from a terminal:

```bash
/Applications/OpenDefendrWatchr.app/Contents/MacOS/OpenDefendrWatchr --notify-test
```

It carries the current live reading — not placeholder text — so a delivered banner also
confirms sampling works. It reports the real outcome and exits non-zero if delivery was
refused, instead of claiming success:

```
$ ./dist/OpenDefendrWatchr.app/Contents/MacOS/OpenDefendrWatchr --notify-test
Notification delivered. If you did not see a banner, check Notification Centre and
System Settings ▸ Notifications ▸ OpenDefendrWatchr, and make sure a Focus mode is not
suppressing it.
```

If permission was never granted or was revoked, it says so and names the setting to flip.
A test never counts as a threshold crossing, so it cannot disturb the hysteresis state.

To confirm the banner was genuinely presented and not silently swallowed by a Focus mode:

```bash
log show --last 5m --predicate 'process == "usernoted"' --style compact \
  | grep -i opendefendr | grep -i present
```

## The log

```
~/Library/Application Support/OpenDefendrWatchr/wdavdaemon-memory.csv
```

Reveal it from the menu ("Reveal Log in Finder"). One row per poll, rotated at 4 MB with
three generations kept:

```csv
timestamp,process,rss_bytes,rss_human,process_count,system_total_bytes,system_free_bytes,system_compressed_bytes,page_size,severity
2026-08-22T06:40:04Z,wdavdaemon,20303237939,18.91 GB,1,25769803776,139116544,9371402240,16384,critical
```

Raw byte columns for graphing, human-readable columns for pasting into a bug report. When
Defender is not running the byte column is empty rather than `0`, so a gap plots as a gap
instead of a fake drop to zero.

## How the memory reading works

- Processes are enumerated with `libproc` (`proc_listallpids` + `proc_pidpath`) and matched
  on the **exact executable file name**, so the siblings `wdavdaemon_enterprise` and
  `wdavdaemon_unprivileged` are never silently folded into the number.
- Resident size comes from `proc_pid_rusage` where permitted. `wdavdaemon` runs as root, so
  that returns `EPERM` for a normal user; the app then makes a single
  `ps -o rss= -p <pids>` call per tick for exactly those PIDs.
- System memory comes from `host_statistics64(HOST_VM_INFO64)`, with the page size queried
  via `host_page_size` — it is 16384 on Apple silicon and 4096 on Intel, and is never
  hardcoded.

## License

Not yet specified.
