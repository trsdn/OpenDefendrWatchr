# OpenDefendrWatchr

A tiny macOS menu bar app that watches Microsoft Defender's `wdavdaemon` process for
runaway memory growth and warns you **before** the machine dies.

## Why this exists

An Apple silicon Mac with 24 GB of RAM became unusable. The system logs tell the whole
story:

- A `JetsamEvent` report fired in the early morning. At that instant free memory was
  **8491 pages of 16 KB (~139 MB)**, the compressor held **571,985 pages (~9.4 GB)**, and
  the single largest process was **`wdavdaemon` at 18.91 GB resident** (1,154,000+ `rpages`).
  The runners-up were trivial by comparison: a browser helper at 1.41 GB and
  WindowServer at 1.13 GB.
- Immediately afterwards `bluetoothd` began crashing with `EXC_CRASH`/`SIGABRT` every
  3–20 minutes — two dozen crash reports over the following three hours, collateral damage
  from memory starvation.
- The machine had to be force-restarted. There is **no kernel panic report**: this was
  memory starvation and unresponsiveness, not a panic.

The goal is not to fix Defender. The goal is to never be surprised again: warn early
enough to save work and reboot deliberately, and collect hard evidence for an IT ticket.

### The second failure mode

Later the same day the machine took a **kernel panic** — and it had nothing to do with
memory. The panic string was `userspace watchdog timeout: no successful checkins from
WindowServer (2 induced crashes) in 120 seconds`, and the report explicitly records
`"memoryPressure": false`, `pagesWanted: 0`. `wdavdaemon` was a harmless 55.69 MB.

The stackshot showed why: WindowServer's main thread was blocked in the kernel's
`com.apple.iokit.EndpointSecurity` extension — along with **47 threads across ~40
processes**, including `tccd`, `opendirectoryd`, `authd`, `coreaudiod` and `watchdogd`
itself. The machine's only Endpoint Security client is Microsoft Defender's
`com.microsoft.wdav.epsext`, which had been logging IPC watchdog timeouts at roughly eight
per second for the preceding hour. Every process that touched a file blocked; WindowServer
was killed, restarted, blocked again, and the kernel gave up.

So the same product can take the machine down two entirely different ways: by leaking
memory, and by stalling Endpoint Security. **The first version of this app was blind to the
second** — it reported `normal` for all 1260 samples up to 70 seconds before the panic.
That is why it now measures filesystem latency too (see below).

## What it does

- Polls `wdavdaemon` resident memory on a configurable interval (default 30s).
- Reads how much memory jetsam considers available (`kern.memorystatus_level`) and warns
  at 20%, critical at 10%.
- **Measures Endpoint Security stalls** by timing `open()`/`close()` on a small warm file.
  Every open is authorised by the ES layer, so this latency is a direct measurement of an
  ES client blocking. Healthy on this machine: median **8.5 µs**. A stall pushes it into
  seconds.
- Shows the current figure compactly in the menu bar (`18.9G`) with a shield glyph whose
  **shape** changes with severity — normal / warning / critical — so it stays legible in
  both light and dark menu bars.
- Notifies **once** per threshold crossing, with debounce and hysteresis. It re-arms only
  after *every* driver has receded.
- Appends every sample to a rotating CSV log — the evidence for the ticket.
- Handles "Defender isn't running" as its own state (`—`) instead of pretending it is 0 B.

### Thresholds

| Level | Default | Meaning |
|---|---|---|
| Warning | 8 GB | `wdavdaemon` is far past normal (~100 MB) and worth watching. |
| Critical | 12 GB | Save your work; consider a deliberate reboot. |

Both are editable in Preferences and persisted.

Severity is the **worst of three independent verdicts**: the watched process, kernel memory
pressure, and filesystem stall. Anchoring it to the process alone is what made the app miss
the panic. Filesystem latency warns at 25 ms and goes critical at 250 ms — roughly three
and four orders of magnitude above the measured healthy baseline, so ordinary scheduling
jitter cannot reach it.

> **Two numbers that look right and are not.** macOS deliberately keeps the free list
> near-empty: in a real 1260-sample log from entirely normal operation, `free < 5%` held
> **99.3%** of the time. And `kern.memorystatus_vm_pressure_level`, the obvious candidate,
> *latches* — measured here it reported `warning` continuously while
> `kern.memorystatus_level` reported **46% available**. Both are constants dressed as
> signals. The app logs the raw dispatch level as evidence but alarms on the percentage.

## The tamper protection limitation (read this)

On the affected machine:

```
mdatp health --field tamper_protection        → "block"
mdatp health --field real_time_protection_enabled → true
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

- macOS 14 or later (developed and verified on Apple silicon)
- Swift 6.1 toolchain or newer (Xcode command line tools). The manifest targets 6.1
  because that is what the signing broker's runner provides.

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

### Updates

The app checks [GitHub Releases](https://github.com/trsdn/OpenDefendrWatchr/releases) for a
newer version once a day (and on demand via **Check for Updates…** in the menu), using
[AppUpdater](https://github.com/mxcl/AppUpdater). A newer release is downloaded and validated
in the background; nothing is installed until you choose **Install Update X.Y.Z and
Restart**, which pauses monitoring, replaces the app and relaunches it. Automatic checks can
be switched off in the menu or in Settings. A failed background check is only logged.

AppUpdater only accepts a release asset named exactly `OpenDefendrWatchr-X.Y.Z.dmg` whose app
carries the same Team ID, signing identifier and bundle identifier as the running one. The
broker publishes that file alongside the versioned `-macOS-arm64` zip and dmg, so no manual
upload is needed. Builds from `make bundle` are signed differently and will refuse updates.

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

## Surviving a reboot

A watchdog that does not come back is worse than no watchdog, for the same reason: you will
assume it is still watching. This one was once started by hand out of a build directory,
so an ordinary restart ended monitoring and nothing said so for 30 hours.

Install it properly and register it, then **read the state back** rather than trusting that
the click worked:

```bash
make install
/Applications/OpenDefendrWatchr.app/Contents/MacOS/OpenDefendrWatchr --login-item enable
/Applications/OpenDefendrWatchr.app/Contents/MacOS/OpenDefendrWatchr --login-item status
```

```
launch at login: enabled
bundle: /Applications/OpenDefendrWatchr.app
```

The command exits non-zero when the state does not match what was asked, and it
distinguishes `requiresApproval` — registered but still switched off in System Settings ▸
General ▸ Login Items — from `notRegistered` and `notFound`. Only one of those three is
something you can fix, and reporting all of them as "off" would hide which.

`SMAppService` needs a real installed bundle: run from `swift run` or a bare binary the
command refuses rather than silently doing nothing.

macOS confirms the registration independently, which is worth checking once:

```bash
log show --last 5m --predicate 'subsystem == "com.apple.backgroundtaskmanagement"' \
  --style compact | grep -i opendefendr
```

This covers loss at reboot, which is the only way the app has actually died. It does **not**
restart the app after a mid-session crash — there has never been one (no crash report, and
no jetsam kill across six jetsam events), so `KeepAlive` would be untested machinery
guarding a failure that has not happened, and it would race with the login item for
ownership of the process.

## The log

```
~/Library/Application Support/OpenDefendrWatchr/wdavdaemon-memory.csv
```

Reveal it from the menu ("Reveal Log in Finder"). One row per poll, rotated at 4 MB with
three generations kept:

```csv
timestamp,process,rss_bytes,rss_human,process_count,system_total_bytes,system_free_bytes,system_compressed_bytes,page_size,available_pct,pressure_level,kernel_pressure_raw,stall_us,swap_total_bytes,swap_used_bytes,swap_used_pct,severity
2026-01-01T00:00:00Z,wdavdaemon,20303237939,18.91 GB,1,25769803776,139116544,9371402240,16384,3,critical,critical,11.2,19327352832,18874368000,97.7,critical
```

Raw byte columns for graphing, human-readable columns for pasting into a bug report. When
Defender is not running the byte column is empty rather than `0`, so a gap plots as a gap
instead of a fake drop to zero. `stall_us` is the median `open()` latency in microseconds;
it should sit in single digits, and a jump into the thousands is an Endpoint Security stall.

`rss_human` carries three distinguishable outcomes and never conflates them: a size, `not
running`, or `unreadable: <reason>`. Swap is recorded for correlation only — a nearly full
swap file is normal on a long-uptime machine and never raises severity by itself. Every
column that could not be measured is left **empty**, never zero.

If the header ever stops matching the columns being written — because a version added one —
the file is rotated rather than appended to. A log whose header mislabels its own columns is
worse than no log during an incident.

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
- Memory pressure comes from `kern.memorystatus_level`. The raw
  `kern.memorystatus_vm_pressure_level` is logged alongside it for evidence, but never used
  to decide severity.

### Why the `ps` call cannot be removed

It is the app's only fork, and it is not there by choice. Measured on the affected machine
against root-owned `wdavdaemon`:

| Attempt as a normal user | Result |
| --- | --- |
| `proc_pid_rusage(pid, …)` | `-1`, `errno 1` (EPERM) |
| `proc_pidinfo(pid, PROC_PIDTASKINFO, …)` | `0` bytes copied, `resident_size` unset |
| `proc_pidinfo(pid, PROC_PIDTASKALLINFO, …)` | `0` bytes copied |
| `sysctl(KERN_PROC_ALL)` | enumerates fine, but `struct vmspace` in the macOS SDK is entirely `dummy` fields — there is no RSS in it |
| `ps -o rss= -p <pid>` | works |

`/bin/ps` is `-rwsr-xr-x root wheel` — **setuid root**. That, and only that, is why it can
read the figure. No `sysctl` route substitutes for the privilege. Process *enumeration* is
already fork-free via `libproc`; only the resident size of root-owned PIDs needs the spawn.

Since the fork cannot be removed, the app is built to fail loudly instead — see below.

## When the machine will not let the app measure

On 28 August 2026 the process table was exhausted machine-wide. Between **03:53:42 and
07:57:29** — nearly four hours, ending 30 seconds before a reboot — the unified log recorded
**796 failed process spawns** across four mutually unrelated applications:

| Process | Failed spawns |
| --- | --- |
| OpenDefendrWatchr | 415 |
| iStat Menus Menubar | 376 |
| com.microsoft.teams2.agent | 4 |
| SetappAgent | 1 |

All with `NSTask: Failed to spawn task due to receiving EAGAIN many times despite retrying`.
This is worth stating precisely, because the impact of process-table exhaustion is usually
described as "eventually you cannot open a terminal any more". What is actually documented
here is stronger: **arbitrary, unprivileged, third-party applications were unable to start
subprocesses for four hours**, and none of them had anything to do with the leak causing it.

The 415 failures are not this app pushing: at a 30 s poll that window holds ~487 ticks, so
0.85 messages per tick — one per attempt, at the normal cadence. `NSTask` emits the message
once after exhausting *its own* internal retries. The app is not amplifying the shortage.

What the app did get wrong was the response. A failed `ps` spawn threw out of the whole
tick, discarding the system and stall readings that had already been taken and needed no
fork at all — and the failure path wrote no CSV row. The log therefore contains a
**221-minute hole** (03:55:28 → 07:36:51 local) that is indistinguishable from the app not
running. A watchdog that goes quiet exactly when the machine is in trouble is useless in the
only hour that matters.

That is fixed. A tick whose process reading fails now:

- keeps the system and stall readings, so the machine verdict still stands;
- reports `?` in the menu bar — not `—`, which means "Defender is not running", and not a
  stale figure;
- writes a CSV row with an empty `rss_bytes` and `unreadable: process table exhausted
  (EAGAIN)` in `rss_human`.

Severity is deliberately *not* raised by a failed reading. An unreadable process contributes
`.normal`, exactly like an absent one, because a measurement that could not be taken must
not manufacture an alert. It must not be presented as a healthy reading either, which is why
the blindness is carried in the menu bar and the log instead of being folded into a number.

## How the stall detection works

The probe opens and closes a 64-byte file it owns, 25 times, and takes the **median**
duration. The file stays in the page cache, so disk speed is not a variable; what remains is
the kernel-side Endpoint Security authorisation round-trip.

This is deliberately vendor-neutral. It would have been possible to count Defender's
`epsext` IPC watchdog timeouts out of the unified log, but that costs ~2 s per query, and it
depends on a private log format that Microsoft can change at any time. Measuring the
*symptom* is cheaper (a probe costs ~0.2 ms), more honest, and catches any ES client
stalling — not just this one.

A probe that cannot run reports **no data**, never a fast reading. Absence of evidence must
not silently disarm the alarm.

## License

Not yet specified.
