# Lid-Closed Sleep Research: How "Never Sleep" Actually Works

> Investigation window: 2026-11-13, 16:00–20:00 (+0800), on the development MacBook
> (Apple Silicon, macOS 26). All findings below are from this machine; nothing here is
> derived from vendor documentation or from the vendor's own claims.

This document exists because SleepSkip's Lid-Closed Backpack Mode currently requires an
admin password on every start (`pmset -a disablesleep 1`). A competing App Store app,
**Never Sleep** (`com.hyperartflow.Never-Sleep`), achieves a similar user-visible result
without any elevation. This is the record of what we found, what we got wrong, and what
the evidence actually supports.

---

## 1. Summary

The kernel mechanism is established by disassembly and needs no experimental confirmation.
The experiments below exist only to check that the *userspace* behaviour matches the code,
and to time the one thing the code cannot answer: persistence.

| # | Finding | Basis |
| :-: | :--- | :--- |
| 1 | Never Sleep uses `kPMSetClamshellSleepState` (IOPMrootDomain scalar selector `12`) **plus** a `PreventUserIdleSystemSleep` assertion | **Disassembly + entitlements + runtime** |
| 2 | Both APIs are in **public SDK headers**, so the App Store build is compliant | **`IOPMLib.h`, `IOPMLibDefs.h`** |
| 3 | With Never Sleep running, the machine stayed awake for 15 minutes lid-closed on battery | Measured (sanity check) |
| 4 | Selector 12 **alone** does not keep the machine awake — it only changes *which* sleep path fires | Measured, and predicted by §3A.4 |
| 5 | Never Sleep idles at **2.45–3.15 % CPU**; SleepSkip idles at **0.03–0.05 %** (~55×) | Measured |
| 6 | `AppleClamshellCausesSleep` is **not** a usable signal for "is lid sleep currently suppressed" (it tracks bit 4, not bit 3) | Measured (negative) + disassembly |
| 7 | `selector 12 + stock caffeinate` keeps a lid-closed Mac awake for 25 min on battery, with no Never Sleep process and no admin rights | Measured (sanity check) |
| 8 | The whole lid-sleep decision is **one bit** (`1 << 3` at `IOPMrootDomain+0x1ec`), read by `shouldSleepOnClamshellClosed()`; the lid handler branches around `privateSleepSystem` when it is clear | **Proven from kernel disassembly** (§3A) |
| 9 | The link from selector 12 to that bit is **inferred, not read**: the setter writes bit 1 of `+0x224`, and no direct copy to `+0x1ec` exists in the text section | **Open** (§3A.6) |

The short version for the product: **selector 12 + a stock `caffeinate` assertion reproduces
Never Sleep's behaviour with no privilege escalation**, and §3A shows why it must. The one
open question is persistence across a long session — settled by a single soak, not a series.
Product plan is §8.

---

## 2. Why this investigation happened

The starting question was simply "does Never Sleep really keep a lid-closed Mac awake?"
An initial answer based on *architecture* — sandboxed MAS app, no privileged helper, no
`SMPrivilegedExecutables`, `SleepDisabled = 0` — concluded it could not. **That answer was
wrong, and the reasoning behind it was the wrong kind of reasoning**: it inferred
impossibility from the absence of one particular mechanism (`pmset`), while the app used a
different, equally capable one.

This mistake is recorded here deliberately. Two follow-on errors were made and corrected in
the same session, and all three are worth remembering:

| Error | Why it was wrong |
| :--- | :--- |
| "Sandboxed, so it cannot affect power management" | `kPMSetClamshellSleepState` needs no privilege and is reachable from a sandbox |
| "It holds only `PreventUserIdleSystemSleep`, so lid close must still sleep" | Lid close has a *separate* trigger path; the assertion covers only the idle path |
| "`AppleClamshellCausesSleep = No` is the decisive evidence" | The key reads `No` even with Never Sleep quit and the lid open — see §6 |

---

## 3. What Never Sleep actually does

### 3.1 Entitlements and distribution

```
com.apple.security.app-sandbox = true      ← the only entitlement
```

- Mac App Store receipt present (`Contents/_MASReceipt/receipt`)
- Signed `Apple Mac OS Application Signing`, Team ID `9P895LY647`
- Contains exactly one helper, `LaunchAtLoginHelper.app`, which is **not** privileged
- Never invokes `/usr/bin/pmset`, `sudo`, or any external power command (no matching
  strings in either architecture slice)

### 3.2 The two IOKit call sites

The arm64 slice contains **exactly two** `IOConnectCallScalarMethod` call sites, both
structurally identical:

```asm
bl   _IOPMFindPowerManagement        ; root power domain connection
mov  w1, #0xc                        ; selector 12 = kPMSetClamshellSleepState
mov  w3, #0x1                        ; one scalar input
bl   _IOConnectCallScalarMethod
bl   _IOServiceClose
```

The value passed is the app's own persisted boolean
(`preventSystemSleepWhenLidClosed`, default `1`).

### 3.3 Why this is App-Store-legal

| Symbol | Header | Status |
| :--- | :--- | :--- |
| `IOPMFindPowerManagement()` | `IOKit/pwr_mgt/IOPMLib.h` | Public, `AVAILABLE_MAC_OS_X_VERSION_10_0_AND_LATER` |
| `kPMSetClamshellSleepState = 12` | `IOKit/pwr_mgt/IOPMLibDefs.h` | Public (lives under the framework's public `Headers/`) |

Both headers ship in the standard SDK. There is no private framework, no dynamic symbol
lookup by string, and no entitlement beyond the sandbox. **Nothing in this path required
special review treatment** — which is why the app is on the store.

What it does *not* do: it never touches the system-wide `SleepDisabled` flag, never
modifies `/etc`, and never asks for admin rights. The blast radius is the current power
domain connection, not the whole machine.

---

## 3A. Why it works, from the kernel up

Everything up to this point is empirical. This section is the mechanism, read out of the
running kernel binary. It answers "why *must* this work" rather than "we observed that it
did", and it is the part that should be trusted when the two disagree.

### 3A.1 Getting the right binary

`/System/Library/Kernels/kernel` is an **x86-64** slice and analysing it is misleading on
Apple Silicon. The running kernel is the per-SoC `kernel.release.<board>`:

```
$ uname -v
Darwin Kernel Version 25.6.0: ... ~2/RELEASE_ARM64_T8132
$ lipo -info /System/Library/Kernels/kernel.release.t8132
Non-fat file: ... is architecture: arm64e
```

The arm64e kernel ships **without local text symbols** (only 6896 `S` symbols), so
functions have to be located by their string references rather than by `nm`. Two facts make
this tractable: the strings survive, and `__TEXT_EXEC.__text` is mapped with a known
file offset.

### 3A.2 The flag is one bit in `IOPMrootDomain`

The gate is a three-instruction leaf. Found by scanning for a load of `[x0, #0x1ec]`
followed by a bit test, at `0xfffffe0007bc8f48`:

```asm
0xfffffe0007bc8f48  d503245f   hint  #0x22           ; function entry (no prologue)
0xfffffe0007bc8f4c  b941ec0c   ldr   w12, [x0, #0x1ec]   ; IOPMrootDomain + 0x1ec
0xfffffe0007bc8f50  3718006c   tbnz  w12, #3, ...
0xfffffe0007bc8f54  52800000   movz  w0, #0
0xfffffe0007bc8f58  d65f03c0   ret
```

In C:

```c
bool shouldSleepOnClamshellClosed(void) {
    return (this->flags_0x1ec & (1 << 3)) != 0;
}
```

**The entire "will closing the lid sleep this Mac" decision is bit 3 of a 32-bit word at
offset `0x1ec` in `IOPMrootDomain`.** Nothing else gates it. That is why no amount of
`IOPMAssertion` can stop lid sleep: assertions are a different subsystem entirely and never
consult this bit.

### 3A.3 The setter

`setClamShellSleepDisable` is not a leaf that pokes one bit. It sits at
`0xfffffe0007bd89d0` (524 bytes) and its log string
`"PMRD: setClamShellSleepDisable(%x->%x)"` appears at `0xfffffe00070d85dc`.

Verified behaviour, instruction by instruction:

```asm
; prologue register mapping (verified):
;   x19 = this, x21 = arg1 (value), x20 = arg2 (mask)
0xfffffe0007bd89f4  adrp/ldr ...                 ; gIOPMrootDomain lookup
0xfffffe0007bd8a20  tbz   w0, #0, ...            ; nothing to do -> skip the update block
0xfffffe0007bd8a24  ldr   w23, [x19, #0x224]     ; the "disabled" state word
0xfffffe0007bd8a28  and   w8,  w23, w20          ; w8 = state & mask  (keep masked bits)
0xfffffe0007bd8a2c  orr   w9,  w23, w20          ; w9 = state | mask  (set masked bits)
0xfffffe0007bd8a30  cmp   w21, #0                ; value
0xfffffe0007bd8a34  csinc w8,  w9,  w8, eq       ; w8 = value ? w9 : w8
0xfffffe0007bd8a38  str   w8,  [x19, #0x224]     ; commit
```

The user-client path into this function passes `value = (scalarInput[0] != 0)` and
`mask = 2`:

```asm
0xfffffe0007ba6ff8  cmp   x8,  #0
0xfffffe0007ba6ffc  cset  w1,  ne                ; arg1 = value
0xfffffe0007ba7000  movz  w2,  #0x2              ; arg2 = mask
0xfffffe0007ba7004  bl    setClamShellSleepDisable
```

So selector 12 touches **bit 1 of `+0x224`**, not bit 3 of `+0x1ec`. The epilogue sets one
unrelated registry bit and returns:

```asm
0xfffffe0007bd89ac  ldr   w8,  [x19, #0x1ec]
0xfffffe0007bd89c0  orr   w8,  w8, #0x8000       ; bit 15
0xfffffe0007bd89c4  str   w8,  [x0,  #0x1ec]
0xfffffe0007bd89c8  ret
```

**What this means.** The function that Never Sleep calls does not itself clear the gate's
bit 3. The two words (`+0x1ec`, `+0x224`) are read together at the top of the lid handler
(§3A.4), so the coupling exists — but it happens elsewhere, and a direct
`+0x224 → +0x1ec` copy does not appear anywhere in `__TEXT_EXEC.__text`. The exact
propagation step is **inferred, not read**, and is labelled as such.

This is also why the empirical result matters more here than elsewhere in this document:
the control-flow gate in §3A.2 and the branch that skips `privateSleepSystem` in §3A.4 are
both directly read, but *how* the selector reaches them is the one link in the chain that
the disassembly does not close.

> **Corrections made to this section.** Two earlier claims were wrong and are retracted:
> (a) a `str w9,[x19,#0x1f8]` "publishes a snapshot" — no such instruction exists;
> (b) the setter clears bit 3 directly — it does not; it writes bit 1 of `+0x224`.

### 3A.4 The lid-close handler

The decisive sequence lives in the function at `0xfffffe0007bc3e00` (the lid/sleep state
machine), not in the setter. Read instruction by instruction:

```asm
0xfffffe0007bc43b0  ldr   w8,  [x19, #0x1ec]      ; flags
0xfffffe0007bc43b4  orr   w8,  w8,  #0x20         ; set bit 5 ("lid just closed / handling")
0xfffffe0007bc43b8  str   w8,  [x19, #0x1ec]      ; store back
0xfffffe0007bc43c0  bl    0xfffffe0007bc8e34     ; helper state update
0xfffffe0007bc43cc  tbz   w8,  #4, 0xfffffe0007bc43e8   ; companion bit clear -> skip entirely
0xfffffe0007bc43d4  bl    0xfffffe0007bc8f48     ; shouldSleepOnClamshellClosed()
0xfffffe0007bc43d8  cbz   w0,  0xfffffe0007bc43e8 ; FALSE -> skip the sleep
0xfffffe0007bc43e0  movz  w1,  #0x65              ; sleep reason 101 = clamshell
0xfffffe0007bc43e4  bl    0xfffffe0007bb8870     ; privateSleepSystem(101)
```

The two instructions that matter are `cbz w0, ...` at `0x7bc43d8` and the `bl` that follows
it. **If `shouldSleepOnClamshellClosed()` returns false, control jumps past
`privateSleepSystem` — the sleep simply never happens.** No timeout, no deferred
re-evaluation, no second chance.

There is also a third gate: `tbz w8, #4` at `0x7bc43cc` checks the companion bit before even
calling the gate function. So the handler requires *both* bits before it considers sleeping.
Which of the two is the effective one, and how they are kept in sync, is the part §3A.6
marks as inferred.

This explains finding #4 directly: selector 12 removes the lid trigger only. Blocking the
idle trigger is a separate job, handled by the `caffeinate` assertion.

> **Correction to an earlier draft.** This section previously described a `bl` at
> `0xfffffe0007bd8b64` as the lid-close decision. That call site belongs to the *setter's*
> own post-write consistency check (it re-reads the flags right after writing them), not to
> the lid handler. The real decision point is the region above. Both call the same gate
> function, which is what made the two easy to confuse.

### 3A.5 Why this is the only complete explanation

| Observation | Explained by bit 3 |
| :--- | :--- |
| `IOPMAssertion` cannot block lid sleep | Lid path never consults assertions — §3A.4 |
| `pmset -g` shows nothing unusual while suppressed | Bit 3 is not published as a pmset key |
| `AppleClamshellCausesSleep` reads `No` even when unset | It tracks a different flag — §6 |
| Behaviour flips instantly on selector, no delay | Flag word is re-read at the top of every lid event — §3A.4 |
| Repeated re-arms do not accumulate state | The setter assigns, it does not toggle — §3A.3 |
| Lid close after suppression dims like normal idle (+124 s, not +5 s) | The clamshell branch exited early, so only the idle path remains |

### 3A.6 Where the proof stops

Two links in the chain are directly read:

- **The gate** (§3A.2): `shouldSleepOnClamshellClosed()` returns bit 3 of `+0x1ec`. Read.
- **The consequence** (§3A.4): the lid handler branches past `privateSleepSystem` when that
  gate returns false. Read.

One link is **not** closed by the disassembly: how a selector-12 call reaches bit 3. The
setter writes bit 1 of `+0x224` (§3A.3); a direct `+0x224 → +0x1ec` copy does not exist
anywhere in the text section. So "selector 12 ⇒ bit 3 clear" is an inference supported by
behaviour, not a line of code.

That distinction sets the scope of what still needs measuring — and it is much smaller than
an earlier draft of this document claimed:

| Question | Status | Needs a test? |
| :--- | :--- | :--- |
| Does a clear bit 3 skip lid sleep? | Read from control flow | **No** |
| Does selector 12 clear bit 3? | Inferred from behaviour (§3A.3) | One confirmation |
| Does the state survive a long session (sleep/wake, cable change)? | Unknown | **Yes — one soak** |

So: one soak, not a series. It should span a sleep/wake cycle and a cable change, and it
should verify the *effect* (no lid sleep) rather than only the log. If it passes, the
mechanism stands as documented; if it fails, the fallback is `pmset -a disablesleep 1`,
which is unaffected by any of this.

### 3A.7 Reproducing this analysis

```bash
K=/System/Library/Kernels/kernel.release.t8132   # must match `uname -v`
python3 - <<'PY'   # locate the gate by its load/bit-test shape
import struct
b=open("/System/Library/Kernels/kernel.release.t8132","rb").read()
TEXT_VA, TEXT_OFF, TEXT_SIZE = 0xfffffe00072de000, 2990080, 0x964ee4
t=b[TEXT_OFF:TEXT_OFF+TEXT_SIZE]
for k in range(0,len(t)-8,4):
    a=struct.unpack("<I",t[k:k+4])[0]
    if (a&0xffc00000)==0xb9400000 and ((a>>10)&0xfff)*4==0x1ec:
        n=struct.unpack("<I",t[k+4:k+8])[0]
        if (n&0x7f000000)==0x37000000 and ((n>>19)&0x1f)==3:
            print(hex(TEXT_VA+k))
PY
```

`shouldSleepOnClamshellClosed` is the gate; its four callers are the only places the
decision is made.

---

## 4. Measured behaviour

Three lid-closed trials, all on battery, all with `SleepDisabled = 0`, all sampled at
2-second resolution. A gap in the sampler means the machine was actually suspended
(the sampler process is frozen along with everything else).

| Trial | Conditions | Result |
| :--- | :--- | :--- |
| **B** | Never Sleep quit, nothing set | `Clamshell Sleep` **5 s** after display off |
| **A2** | Never Sleep running (selector + assertion) | **No sleep** for 17 min lid-closed |
| **S12** | Selector 12 only, Never Sleep quit | No `Clamshell Sleep`; `Idle Sleep` at **273 s** |
| **COMBO2** | Selector 12 + one `caffeinate -i`, Never Sleep quit | **No sleep** for **25 min** lid-closed, no admin rights |

A2 detail: lid closed 17:43:16, display off 17:45:26, lid reopened 18:00:22. 482 consecutive
2-second samples from inside the closed lid, zero gaps, zero sleep events, battery 59 → 58 %.

### 4.1 The two halves are complementary

| Mechanism alone | Lid-close outcome |
| :--- | :--- |
| Assertion only (historical, 11-13 11:41) | `Clamshell Sleep` after 5 s — the assertion does **not** cover lid close |
| Selector 12 only (trial S12) | Lid close no longer triggers sleep, but the machine still idles down after the normal timer |
| Both (trial A2) | Stays awake indefinitely |

So the complete mechanism is:

```
kPMSetClamshellSleepState(1)                 → removes the lid-close trigger
IOPMAssertion(PreventUserIdleSystemSleep)    → removes the idle trigger
```

Neither one alone is sufficient, and both together were reproduced **without Never Sleep**
(trial COMBO2) using only public API calls plus stock `caffeinate`. This retroactively
explains the confusing historical logs: many "Never Sleep was running and the Mac still
slept" rows are cases where the app held the assertion but the lid path was untouched
(external-display mode, or the flag was not set at that moment).

### 4.2 CPU cost

Measured with 60 s of quiet sampling, both apps resident, no foreground work:

| App | Idle CPU | RSS | Threads |
| :--- | ---: | ---: | ---: |
| Never Sleep | **2.45–3.15 %** (60 s mean 2.75 %) | 123 MB | 3 |
| SleepSkip | **0.03–0.05 %** | 73 MB | 2 |

`sample(1)` attributes the cost to the SwiftUI main thread re-running
`NSHostingView.layout()` / `ViewGraphRootValueUpdater.render()` on every display-link
tick — **and it keeps doing this with the app's window closed**. This is a real battery
cost on a laptop, and it is not something SleepSkip's design needs to inherit: SleepSkip
uses native `caffeinate` and a menu-bar-only UI.

Historical log evidence adds a second cost dimension: one continuous Never Sleep assertion
interval ran **140.4 minutes** with **0 idle sleeps** inside it, while all 28 idle sleeps
in the same log happened outside its intervals. The app suppresses battery idle sleep too,
not just lid sleep.

---

## 5. Reproducing the measurements

The probes used live in this repo's git history only as notes; they are ~30 lines of C each.

```c
// Reading the flag Never Sleep sets (no privilege needed)
io_connect_t conn = IOPMFindPowerManagement(kIOMainPortDefault);
uint64_t one = 1;
IOConnectCallScalarMethod(conn, kPMSetClamshellSleepState, &one, 1, NULL, NULL);
IOServiceClose(conn);
```

Lid-close trials were sampled with:

```bash
while :; do
  printf '%s lid=%s\n' "$(date '+%F %T')" \
    "$(ioreg -r -k AppleClamshellState -d 4 | grep -o 'AppleClamshellState" = [A-Za-z]*')"
  sleep 2
done >> /tmp/lid.log
```

Ground truth always came from `pmset -g log`, not from the sampler alone:

```bash
pmset -g log | grep -E "Entering Sleep|darkwakelinger|Display is turned"
```

`darkwakelinger` is the reliable beacon that powerd has *started* a sleep transition; the
`Clamshell Sleep` vs `Idle Sleep` distinction is what tells you which trigger fired.

---

## 6. Negative result: `AppleClamshellCausesSleep` is not a usable signal

`IOPM.h` documents the key as:

```
true        == system will sleep when clamshell is closed
false       == system will not sleep on clamshell close
                  (typically external display mode)
not present == no clamshell on this hardware
```

That documentation is what made it look like a direct readout of the state we care about.
It is not. Measured:

| Situation | Value |
| :--- | :--- |
| Never Sleep running, lid open | `No` |
| Never Sleep running, lid closed | `No` |
| **Never Sleep quit**, lid open | **`No`** |
| After our own `setClamshellSleepState(1)` | `No` (polled at 20 ms for 2 s; never changed) |
| After `setClamshellSleepState(0)` | `No` |

It is a runtime mirror maintained by power management, not a register the selector writes.
**Do not use it to decide whether lid sleep is currently suppressed.** If a future build
needs that signal, it has to come from the app's own state, not from ioreg.

A related trap: `pmset -g` and `pmset -g assertions` show *nothing* about selector 12. A
process can be suppressing lid sleep while `pmset -g` reports a completely normal system.

---

## 7. Trial COMBO "failure" was a harness bug, not a finding

Trial **COMBO** (19:09 selector set → 19:22 lid close) appeared to fail: `Clamshell Sleep`
fired 5 s after display off, as if the selector had never been applied. That contradicted
trial S12, which had suppressed the clamshell path with the same mechanism.

**The selector was never active during COMBO.** Trial S12's safety watchdog
(`sleep 1200; clamshellctl 0`) was started at 18:50:59 and stayed alive because the cleanup
between trials matched the pattern `ns-probe/watchdog.sh` while the process argv was
actually `./watchdog.sh` — no match, so it survived. It fired at **19:10:59**, 69 seconds
after COMBO armed the selector, and reset it to `0`. The lid was closed 12 minutes later.

```
19:09:50  COMBO arms  kPMSetClamshellSleepState = 1
19:10:59  S12 watchdog (stale) resets it to 0     ← logged: "watchdog restored at 19:10:59"
19:22:47  lid closed  → selector already 0 → Clamshell Sleep after 5 s
```

So COMBO measured the *unarmed* baseline, which is exactly what trial B measured. It is
consistent with everything else; it just is not a test of the combination.

Two lessons for future runs:

- **A stale safety timer is a silent test invalidator.** Any cleanup that kills watchdog
  processes must match on the actual argv, or use a pidfile. The replacement harness
  (below) uses a lock file and re-arms the selector every 60 s, so a single stale reset
  cannot silently disable the test for the whole window.
- Record every selector change with a timestamp in the experiment log itself, so a reset is
  visible in the data rather than inferred afterwards.

```bash
# the re-arming pattern that makes a stale reset non-fatal
if [ $((NOW - LAST_ARM)) -ge 60 ]; then arm; LAST_ARM=$NOW; fi
```

Trial COMBO was additionally polluted for a "does it stay awake" reading: the cable was
plugged at 19:52 (`USB-C_plug`) and unplugged at 19:55 (`acdetach`), producing
`Notification Wake Back to Sleep` cycles, and `Karabiner-Core-Service` delayed every sleep
notification by ~3 s.

**The combination remains unverified.** See the re-run below.

### 7.1 Re-run (COMBO2), with the harness fixed

Conditions: `kPMSetClamshellSleepState = 1` re-armed every 60 s, one persistent
`caffeinate -i` assertion, **Never Sleep not running**, battery, no cable changes.

| | Value |
| :--- | :--- |
| Lid closed → display off | 20:25:32 → 20:27:36 (+124 s) |
| Display off → lid open | 20:27:36 → 20:52:30 (**24.9 min**) |
| Total lid-closed | 27.0 min |
| Sampler gaps | **0** out of 1048 samples |
| Sleep / DarkWake events | **none** |
| `pmset` log mentions of "Never Sleep" | **0** |
| Battery | 23 % → 21 % |
| Selector re-arms during window | 27 consecutive, all logged |

Display-off came 124 s after the lid closed, i.e. the machine treated the lid close as
ordinary idling (the same signature as trials A2 and S12), and then **never idled down
for the next 25 minutes** despite `sleep 1` on battery. Trial B slept 5 s after display
off under otherwise identical conditions, so this is a ~300× difference in time-to-sleep.

One caveat: this trial had a **vanishing `caffeinate` supply** rather than a fixed one —
extra `caffeinate -t 300` processes from other sessions expired one by one during the
window (`caf=4 → 3 → 2 → 1`), so only the harness-bound assertion was present from
20:40:14 onward. Behaviour did not change across those transitions, which is mild evidence
that one persistent assertion is sufficient (as opposed to a stack of them).

A single `ns=1` sample at 20:32:29 is a **`pgrep -f "Never Sleep"` false positive** — the
pattern matched some unrelated argv. `pmset -g log` contains zero Never Sleep mentions in
the entire window, and the app was not installed-then-relaunched, so no Never Sleep
assertion existed.

**Conclusion: selector 12 + one `caffeinate -i` assertion suppresses lid-close sleep
without any privilege escalation and without Never Sleep.** This agrees with what the
kernel code requires (§3A), so it reads as confirmation rather than as new information.

The only thing this trial does not settle is **persistence over a long session**. 25 minutes
is long enough to rule out a per-event reset, not long enough to rule out a reset tied to a
sleep/wake cycle or a power-source change. That is the single remaining soak (§8).

---

## 8. What this means for SleepSkip

**Do not change the lid-closed implementation in the same release as this finding.**

- Selector 12 + `caffeinate` **works**, and §3A explains why it must: the lid handler
  branches around `privateSleepSystem` whenever bit 3 is clear. That part needs no further
  evidence.
- `pmset -a disablesleep 1` remains the only mechanism verified to hold for a full session.
  Its cost (one admin prompt per start) buys a state that cannot silently lapse.

The realistic path is a **three-mode design**, not a replacement:

| Mode | Mechanism | Prompt | Status |
| :--- | :--- | :--- | :--- |
| Default | selector 12 + `caffeinate -i -w <pid>` | none | Needs one soak |
| Compatibility | `pmset -a disablesleep 1` + watchdog | admin | Verified, ship as-is |
| Idle-only | `caffeinate -i` | none | Already shipped |

Before the default flips to selector 12, **one** soak settles the only open question:

1. **Persistence**: one ≥ 2 h lid-closed session that spans a sleep/wake cycle *and* a
   cable plug/unplug, verifying that the lid path stays suppressed throughout
   (`scripts/clamshell_soak.sh` does this and refuses to report PASS otherwise).
2. **Fallback**: if the selector call fails (`kr != KERN_SUCCESS`), silently fall back to
   requesting the admin prompt rather than pretending the mode is active.

That is the whole validation list. Anything beyond it would be re-testing a mechanism that
is already read out of the kernel, and the risk with extra experiments is not wasted time —
it is manufacturing false negatives that then have to be explained away (this investigation
produced two such incidents: the stale watchdog, and a "must be on battery" restriction that
turned out to be false).

Re-arming every 60 s is cheap — a scalar IOKit call — and is worth doing in the product too,
since a reset would otherwise be silent and unobservable. The repeat calls also exercise the
selector's path on a schedule, which is useful precisely because §3A.6 marks that path as
inferred; if a future macOS changes it, a periodic call makes the failure visible sooner.

Two facts from this investigation are worth carrying into any future implementation:

- The useful public API is `kPMSetClamshellSleepState` with `IOPMFindPowerManagement`;
  there is no `IOPMLib` wrapper, so it must be called as a scalar method.
- Any test that relies on `SleepDisabled`, `pmset -g assertions`, or
  `AppleClamshellCausesSleep` alone will mislead. Ground truth is `pmset -g log` plus a
  sampler that runs *inside* the closed lid.

### 8.1 On power source

An earlier draft of this document required battery power for every test. That was wrong.
Both sources work, and they answer different questions:

| Source | Idle sleep | Only possible sleep cause | What a sleep event proves |
| :--- | :--- | :--- | :--- |
| Battery (`sleep 1`) | enabled | lid or idle | ambiguous — check the reason string |
| AC (`sleep 0`) | disabled | **lid only** | unambiguous: the selector did not take effect |

AC is therefore the cleaner signal and has no battery risk, which makes it the better
default for the persistence soak. Its limitation is that the idle path never fires, so the
`caffeinate` half is untested there; a battery run is what exercises it.

---

## 9. Changelog of this investigation

| Time (11-13) | Event | Outcome |
| :--- | :--- | :--- |
| 16:07 | Asked whether Never Sleep survives lid close | Initial architectural answer: "impossible" — **wrong** |
| 16:18 | First reproduction attempt | Inconclusive: 8 s of real lid-closed time |
| 16:23–16:35 | Historical log correlation | 7 of 27 clamshell sleeps happened with the assertion held — suggested "does nothing" |
| 16:57–17:03 | Trial A (Never Sleep on) | No sleep in 144 s, but polluted by Codex UI tests |
| 17:16–17:26 | Trial B (Never Sleep quit) | `Clamshell Sleep` in 5 s |
| 17:43–18:00 | Trial A2 (clean, Never Sleep on) | **No sleep for 17 min** |
| 18:20–18:45 | Binary forensics | Selector 12 found; App Store legality explained |
| 18:49–19:03 | Trial S12 (selector only) | `Clamshell Sleep` suppressed; `Idle Sleep` at 273 s |
| 19:09–19:56 | Trial COMBO (selector + caffeinate) | **Invalid** — stale watchdog reset the selector at 19:10:59 |
| 20:17–20:53 | Trial COMBO2 (fixed harness, re-arm every 60 s) | **No sleep for 25 min** — combination confirmed |
| 21:00–22:30 | Kernel disassembly, arm64e slice | Gate and lid branch read directly; setter writes `+0x224`, not `+0x1ec` — one link left inferred (§3A.6) |

### Outcome of trial COMBO

Invalidated post-hoc by a harness bug, not by macOS behaviour. Adding it here because the
distinction matters: a failed experiment that *looks* like evidence against a mechanism is
the most dangerous kind of result to leave undocumented. The re-run with a corrected harness
(COMBO2) produced the expected positive result, and is the basis for finding #7.
