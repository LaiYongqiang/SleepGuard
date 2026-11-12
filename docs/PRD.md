# SleepGuard Product Requirements Document (PRD)

> **Positioning**: An ultra-lightweight native macOS menu bar utility built for Vibe Coding and AI Agent workflows.  
> **Core Philosophy**: Give every watt of battery power to your active AI Agents and background tasks, not an idle illuminated display.

---

## 1. Background & Core Insights

Modern macOS developers frequently run long-lived engineering and AI workflows (Codex CLI, Claude Code, builds, tests, local servers, model inference) while commuting, tethering to mobile hotspots, or stepping away from their desk:

1. **Battery & Thermal Sensitivity**: On fanless MacBook Air or battery-powered MacBooks, keeping the display lit is one of the largest battery and thermal drains.
2. **Separation of Background Compute & Desktop GUI**:
   - **CLI, code generation, builds, tests, local servers, and headless browser jobs** execute cleanly while the screen is off and locked.
   - **Desktop GUI automation (Computer Use / `ScreenCaptureKit` / `CGEvent`)** requires an active, unlocked WindowServer session.
3. **Zero Idle Overhead**: The utility itself must introduce zero background polling and `0.0%` idle CPU wakeups when the popover is closed.

---

## 2. Core Modes & Controls

### 2.1 Two Official Modes

| Mode | Underlying Assertion | Ideal Use Cases |
| :--- | :--- | :--- |
| **Background (Default)** | `/usr/bin/caffeinate -i -w <PID>` | Codex CLI, Claude Code, builds, downloads, local servers, hotspot sessions |
| **Keep Display On** | `/usr/bin/caffeinate -di -w <PID>` | Computer Use GUI agents, presentations, log monitoring, documentation reading |

### 2.2 Portable Security & Backpack Options (Under Background Mode)

1. **Lock on Start** (Enabled by default, remembered): Immediately triggers native macOS screen lock upon starting a background session.
2. **Stay Awake Lid-Closed / Backpack Mode** (Disabled by default, opt-in):
   - Requests standard macOS Touch ID / administrator authorization when enabled.
   - Applies `pmset -a disablesleep 1` guarded by a kernel `kqueue` watcher (`caffeinate -i -w <sentinelPID>`) paired with `trap 'pmset -a disablesleep 0' EXIT INT TERM`.
   - Automatically restores normal sleep (`disablesleep 0`) when stopped manually, when the timer expires, or if the host app exits unexpectedly.
   - Startup performs a one-shot `pmset -g` verification to offer instant recovery if an unexpected power loss left `SleepDisabled = 1`.

### 2.3 Duration Presets & Configuration Memory

- **6 Duration Presets**: `30m`, `1h`, `2h`, `4h` (default safety cap), `Indefinite`, and inline `Custom`.
- **Remember Last Config + Enter to Launch**: Automatically persists mode, lock-on-start, closed-lid preference, and duration. Pressing `Enter` when idle starts immediately with the remembered configuration; pressing `Enter` or `Esc` while running closes the popover without interrupting the active session.

---

## 3. Event-Driven Architecture & Power Guardrails

1. **Zero Background Timers**: Countdown `Timer` runs strictly while `NSPopover` is visible (`popoverWillShow` / `popoverDidClose`).
2. **Lifecycle Binding**: Every `caffeinate` child carries `-w <APP_PID>`, ensuring zero orphaned processes if the app quits or crashes.
3. **Zero-Polling Low-Battery Cutoff**: Optional battery protection (`Off` / `5%` / `10%` / `15%` / `20%`, default `10%`) uses `IOKit.ps` `IOPSNotificationCreateRunLoopSource` callbacks—only activating when discharging on battery.
4. **Native macOS Integration**: Left-click status item opens Popover; right-click opens native context menu; Launch at Login uses `SMAppService.mainApp`.

---

## 4. Architectural Red Lines

1. **No background polling or 1Hz menu bar redraws** when the popover is hidden.
2. **No silent or unguarded system power modifications**: `disablesleep` is strictly opt-in, Touch ID authorized, and self-healing via `kqueue` + `trap`.
3. **No synthetic mouse/keyboard jiggling** to bypass OS lock screen security policies.
4. **No `killall caffeinate`**: process management applies strictly to child handles spawned by SleepGuard.
5. **No heavy runtimes**: zero Electron, WebView, telemetry, or persistent helper daemons.
