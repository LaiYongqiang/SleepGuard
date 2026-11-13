# Measured Resource Usage

Numbers below were taken on an Apple Silicon MacBook (macOS 26) with 860 processes running,
using `scripts/bench_idle.swift`, which reads `proc_pid_rusage` for the process itself.

Reproduce any row with:

```bash
open -a SleepSkip          # or leave it running
swift scripts/bench_idle.swift "$(pgrep -x SleepSkip)" 120
```

## SleepSkip 1.2.0

| State | CPU over 120 s | Forced wakeups | Notes |
| :--- | ---: | ---: | :--- |
| Idle, panel closed, auto-follow off | **0.09–0.24 ms** | 3–11 | Cross-checked with `ps` (`0:00.11 → 0:00.12`) and `top` (`0.0% CPU`) |
| Auto-follow on, agents actively writing | **0.73 ms / 180 s** | 12 / 180 s | Confirmed holding a real assertion via `pmset -g assertions` |
| Panel open (1 Hz countdown) | 1.3 ms / 60 s | ~60 / 60 s | Timer destroyed the moment the popover closes |
| `sleepskip -- <cmd>` wrapping a 10 s task | 10 ms total | — | Bare `/bin/sh` baseline: 0 ms |

Memory, idle: **23 MB** physical footprint (peak 24 MB). `ps` reports 71 MB because its RSS
column also counts shared framework pages; `footprint` is the number that matters.

## Baseline for comparison

A **completely empty** AppKit process that only owns a status bar item — no SleepSkip code at all,
measured three times on the same machine:

| Baseline app | CPU over 120 s | Forced wakeups |
| :--- | ---: | ---: |
| Bare status-item app, run 1 | 0.035 ms | 4 |
| Bare status-item app, run 2 | 0.037 ms | 5 |
| Bare status-item app, run 3 | 0.142 ms | 7 |

SleepSkip idles at 0.09–0.24 ms with 3–11 wakeups: **the same order as a hand-written app that
does nothing but draw a menu bar icon.** Its own logic adds no measurable CPU or wakeups on top
of what macOS imposes on any status item.

This is also the honest limit of the claim: **an AppKit menu bar app cannot have zero wakeups.**
macOS gives every status item a baseline heartbeat. Several SleepSkip runs came out slightly
lower than the minimal baseline, which is run-to-run noise rather than a real advantage. The
precise claim is therefore **"no timers and no polling of our own while the panel is closed"**,
not "zero wakeups" — the weak version is easy for a reviewer to disprove and costs more
credibility than the precise one buys.

## What this rules out

Measured on the same machine while evaluating the auto-follow design:

| Approach | CPU over 30 s | Forced wakeups | Verdict |
| :--- | ---: | ---: | :--- |
| FSEvents on transcript directories (**shipped**) | 0.23 ms | 0 | Used |
| `proc_listallpids` + `proc_pidpath` polling, 2 s | 81 ms | 15 | Rejected |
| Same, 1 s | 161 ms | 21 | Rejected |

Polling costs two orders of magnitude more CPU than event-driven watching, and — more
importantly — wakes the CPU once per second, which is exactly the thing a battery-conscious
tool should not do.
