# SleepSkip · 惜眠

**Your agents aren't done. Your Mac shouldn't sleep.**

A macOS menu bar & CLI keep-awake utility that follows your AI agents instead of a timer. When Claude Code, Codex, or DeepSeek Harness writes, sleep is held off; when they go quiet, sleep comes back.

[中文文档](README_CN.md) · [Product Spec (PRD)](docs/PRD.md) · [Measured resource usage](docs/PERFORMANCE.md)

> **Why not Amphetamine?** It holds the Mac awake for a *duration*. SleepSkip holds it awake for a *task*. It watches agent transcript directories with FSEvents (file changes only, never contents) and releases after a 5-minute grace period — so an agent that finishes early stops costing you battery, and one that runs long doesn't get cut off.

| | Amphetamine / Caffeine | SleepSkip |
| :--- | :--- | :--- |
| Keeps Mac awake | ✅ | ✅ |
| Knows when your agent finished | ❌ | ✅ FSEvents, no polling |
| Idle CPU | menu bar app | **0.09–0.24 ms per 120 s** ([measured](docs/PERFORMANCE.md)) |
| Wrap a command (`sleepskip -- claude …`) | ❌ | ✅ exits with your command |
| Lid-closed mode | ⚠️ unreliable | ✅ explicit, with a watchdog |

---

## Preview

| Idle (Light) | Active Countdown (Light) | Active Countdown (Dark) | Preferences |
| :---: | :---: | :---: | :---: |
| <img src="docs/images/preview-idle-en.png" width="210" alt="Idle Light Preview" /> | <img src="docs/images/preview-running-light-en.png" width="210" alt="Active Light Preview" /> | <img src="docs/images/preview-running-dark-en.png" width="210" alt="Active Dark Preview" /> | <img src="docs/images/preview-settings-en.png" width="210" alt="Preferences Preview" /> |

---

## Why SleepSkip?

Traditional keep-awake tools were designed a decade ago to keep screens lit while reading or presenting. In the AI Agent era, most workflows run headless in the background while your MacBook travels in a sleeve, tethers to a phone hotspot, or sits locked on battery.

SleepSkip is built around first principles:
- **Auto-follow agents** (on by default): watches the transcript folders of Claude Code, Codex, and DeepSeek Harness and holds sleep off exactly while they write, releasing after a 5-minute grace period. Measured cost is **~0.2 ms of CPU per 20 seconds**, with no more wakeups than the menu bar icon itself needs. Process polling was measured at ~160 ms/30 s plus one wakeup per second, and rejected. Only file changes are observed; transcript contents are never read. A manual session always wins, and a 2-hour hard ceiling prevents an accidental all-nighter.
- **No timers, no polling, while the panel is closed**: Powered directly by macOS native `/usr/bin/caffeinate`. The 1Hz countdown timer exists **only** while the popover is open. [Measured](docs/PERFORMANCE.md): 0.09–0.24 ms of CPU per 120 s idle — the same order as a menu bar app that does nothing but draw its icon.
- **Zero Orphan Processes**: Every `caffeinate` assertion is bound via `-w <PID>`. Even if force-quit, the kernel immediately tears down child assertions.
- **Remembered Config + One-Keystroke Launch**: Remembers your last mode, duration, and lock preference. Open the popover and hit `Enter` to start immediately; hit `Enter` or `Esc` to dismiss.
- **CLI Companion (`sleepskip -- <cmd>`)**: Wrap any AI Agent or build command so your Mac stays awake strictly until the task completes, synced passively via kernel `kqueue` events (measured: 10 ms of CPU across a 10 s task).
- **URL Scheme Automation**: Control sessions from Raycast, Alfred, or Apple Shortcuts via `sleepskip://`.
- **Two Clean, Purpose-Built Modes**:
  - **Background** (`caffeinate -i`, default): Prevents idle sleep while turning off the screen to save battery. Includes optional **Lock on Start** and opt-in **Lid-Closed Backpack Mode**.
  - **Keep Display On** (`caffeinate -di`): Keeps both system and WindowServer display rendering active — the reliable native mode for **Computer Use** (`ScreenCaptureKit` / GUI agents) and presentations. *(Tip: lower screen brightness to minimum when running Computer Use unattended.)*
- **Optional Lid-Closed Backpack Mode**: Explicit opt-in with standard macOS Touch ID / admin authorization (`pmset -a disablesleep 1`), protected by a kernel `kqueue` + `trap` watchdog that automatically restores normal sleep (`disablesleep 0`) on stop, timeout, or app termination.
- **Event-Driven Power Protection**: Pre-flight + `IOKit.ps` `IOPSNotificationCreateRunLoopSource` callbacks for optional **Low-Battery Cutoff** (`5%`–`20%`) and **Stop When Unplugged** (zero polling), delivered via native macOS notifications only on passive stops.

---

## CLI Companion & URL Automation

Link the bundled CLI binary once:

```bash
sudo ln -sf /Applications/SleepSkip.app/Contents/MacOS/SleepSkip /usr/local/bin/sleepskip
```

Usage:

```bash
# Keep Mac awake until Codex finishes (poll-free: event-driven)
sleepskip -- codex "refactor auth module"

# Keep display on for a Computer Use run, then lock screen when done
sleepskip --display --lock -- python agent.py

# Watch an already-running process by PID
sleepskip watch 12345 --lock
```

URL Scheme (`Raycast` / `Alfred` / `Shortcuts`):
- `sleepskip://start?mode=background&minutes=240&lock=1`
- `sleepskip://start?mode=display&minutes=60&lock=0`
- `sleepskip://stop`
- `sleepskip://toggle`
- `sleepskip://lock`

---

## Measured Resource Usage

Numbers are reproducible with `swift scripts/bench_idle.swift "$(pgrep -x SleepSkip)" 120`;
the full methodology and the rejected alternatives are in [docs/PERFORMANCE.md](docs/PERFORMANCE.md).

| State | CPU per 120 s | Forced wakeups |
| :--- | ---: | ---: |
| Idle, panel closed | 0.09–0.24 ms | 3–11 |
| Auto-follow on, agents writing | 0.73 ms / 180 s | 12 |
| Panel open (1 Hz countdown) | 1.3 ms / 60 s | ~60 |

For reference, an **empty** AppKit app that only draws a status bar icon idles at 0.035–0.142 ms
per 120 s. SleepSkip sits in the same range — its own logic adds no measurable overhead on top of
what macOS imposes on any menu bar app. That is also why the claim is "no timers and no polling"
rather than "zero wakeups": no status-item app can honestly promise the latter.

---

## Installation & Build

### Homebrew (Recommended — installs both App & `sleepskip` CLI)

```bash
brew install --cask laiyongqiang/tap/sleepskip
```

Homebrew installs `SleepSkip.app` into `/Applications` and links the `sleepskip` CLI. The command is spelled `sleepskip` rather than `skip` because `skip` is already taken by skip.tools on Homebrew.


### Download Release (Universal: Apple Silicon + Intel)

1. Download the latest `SleepSkip-*-macOS-universal.dmg` from [GitHub Releases](https://github.com/LaiYongqiang/SleepSkip/releases) and drag `SleepSkip.app` to `/Applications`.
2. Since release builds are ad-hoc signed without a paid Apple Developer ID, run once if Gatekeeper blocks first launch:
   ```bash
   xattr -cr /Applications/SleepSkip.app
   ```

### Build from Source (macOS 13+)

Requires Xcode Command Line Tools (`swift` 5.10+):

```bash
git clone https://github.com/LaiYongqiang/SleepSkip.git
cd SleepSkip

# Run unit and caffeinate lifecycle tests
./scripts/verify.sh

# Build Universal SleepSkip.app bundle, ZIP, and DMG in ./dist/
chmod +x scripts/build_app.sh
./scripts/build_app.sh
```

---

## Architectural Guardrails

SleepSkip strictly avoids:
1. Background polling (`ps`, `pgrep`, `pmset`) or 1Hz menu bar icon redraws when closed.
2. Silent or unrecoverable system sleep modifications.
3. Synthetic mouse/keyboard jiggling to bypass OS lock screen security.
4. `killall caffeinate` (never touches assertions owned by other apps).
5. Heavy runtimes (zero Electron, WebView, or persistent daemon helpers).

---

## License

[MIT License](LICENSE) © 2026 LaiYongqiang
