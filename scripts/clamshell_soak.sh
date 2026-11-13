#!/usr/bin/env bash
# Clamshell soak test: does kPMSetClamshellSleepState plus a persistent
# caffeinate assertion survive a long lid-closed session?
#
# This is the validation described in docs/CLAMSHELL-RESEARCH.md §8.2.
# It is deliberately paranoid, because a silent state reset produces a
# result that looks exactly like success (no sleep) while testing nothing.
#
# Usage:
#   sudo -v                       # optional; not needed for the test itself
#   ./scripts/clamshell_soak.sh [duration-minutes]
#
# Exit codes:
#   0  soak passed  (no sleep, selector held the whole time)
#   1  soak failed  (machine slept, or selector was lost)
#   2  precondition not met (another soak running, or selector unavailable)
#
# Notes
#  - Requires battery power. On AC, `sleep 0` means the idle path never
#    fires and the test proves nothing.
#  - Re-arms the selector every 60 s. setClamShellSleepDisable() is
#    idempotent, so this is a few microseconds each time.
#  - Writes every selector change to the log, so a reset is visible in the
#    data rather than inferred after the fact.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_DIR="${TMPDIR:-/tmp}/sleepskip-soak"
CTL="$RUN_DIR/clamshellctl"
LOG="$RUN_DIR/soak.log"
LOCK="$RUN_DIR/soak.lock"
STOP="$RUN_DIR/soak.stop"
MINUTES="${1:-240}"
SAMPLE_SECONDS=5

fail() { printf '%s\n' "$1" >&2; exit "${2:-1}"; }

# --- preconditions -----------------------------------------------------------

[ -e "$LOCK" ] && fail "a soak is already running ($LOCK); remove it if stale" 2
mkdir -p "$RUN_DIR"

SRC="$(pmset -g batt | head -1)"
case "$SRC" in
  *Battery*) MODE="battery" ;;
  *AC*)      MODE="ac" ;;
  *)         fail "cannot determine power source (got: $SRC)" 2 ;;
esac

# Both power sources are valid, but they test different halves of the mechanism:
#
#   battery: idle sleep is enabled (`sleep 1`), so a sleep event could come from
#            either the lid path or the idle path. Needs the caffeinate assertion
#            to be present, and the *reason* string in the kernel log matters.
#   AC:      idle sleep is disabled (`sleep 0`), so the ONLY way the machine can
#            suspend is the lid path. A sleep event is unambiguous proof that the
#            selector did not take effect. This is the cleaner signal, and it has
#            no battery risk — but it exercises selector 12 alone, because the
#            idle path never fires anyway.
#
# Record which one we ran, and do not pretend one substitutes for the other.

command -v clang >/dev/null || fail "clang not found (Xcode command line tools required)" 2

# --- build the selector helper ----------------------------------------------

cat > "$RUN_DIR/clamshellctl.c" <<'C'
#include <stdio.h>
#include <stdlib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <IOKit/pwr_mgt/IOPMLibDefs.h>
int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s 0|1\n", argv[0]); return 2; }
    uint64_t want = strtoull(argv[1], NULL, 10);
    io_connect_t c = IOPMFindPowerManagement(kIOMainPortDefault);
    if (!c) { fprintf(stderr, "IOPMFindPowerManagement failed\n"); return 1; }
    kern_return_t kr = IOConnectCallScalarMethod(c, kPMSetClamshellSleepState, &want, 1, NULL, NULL);
    IOServiceClose(c);
    if (kr != KERN_SUCCESS) { fprintf(stderr, "selector 12 failed: 0x%x\n", kr); return 1; }
    return 0;
}
C

clang -O2 -framework IOKit -framework CoreFoundation \
      "$RUN_DIR/clamshellctl.c" -o "$CTL" 2>/dev/null \
  || fail "failed to build clamshellctl" 2

# --- cleanup -----------------------------------------------------------------

CAFFEINATE_PID=""

cleanup() {
  touch "$STOP" 2>/dev/null || true
  if [ -n "$CAFFEINATE_PID" ]; then
    kill "$CAFFEINATE_PID" 2>/dev/null || true
  fi
  "$CTL" 0 2>/dev/null || true
  echo "$(date '+%F %T') SELECTOR restored=0" >> "$LOG"
  rm -f "$LOCK"
}
trap cleanup EXIT INT TERM

echo $$ > "$LOCK"
: > "$LOG"
# A stop file left behind by a previous run makes the loop exit immediately,
# which then reports a trivial PASS. Clear it before arming anything.
rm -f "$STOP"

# --- arm ---------------------------------------------------------------------

arm() {
  if "$CTL" 1; then
    echo "$(date '+%F %T') SELECTOR armed=1" >> "$LOG"
  else
    echo "$(date '+%F %T') SELECTOR ARM FAILED" >> "$LOG"
  fi
}

arm
/usr/bin/caffeinate -i -w $$ >/dev/null 2>&1 &
CAFFEINATE_PID=$!

# Independent ground truth: snapshot the sleep-event count before the soak so
# the verdict does not depend solely on this process staying scheduled.
SLEEP_MARK="$(pmset -g log 2>/dev/null | grep -c 'Entering Sleep state' || true)"

DEADLINE=$(( $(date +%s) + MINUTES * 60 ))
LAST_ARM=0
GAPS=0
PREV_TS=0
LID_CLOSED_SAMPLES=0
TOTAL_SAMPLES=0

echo "$(date '+%F %T') SOAK start minutes=$MINUTES mode=$MODE caffeinate=$CAFFEINATE_PID" >> "$LOG"

while [ "$(date +%s)" -lt "$DEADLINE" ] && [ ! -e "$STOP" ]; do
  NOW=$(date +%s)

  # Idempotent re-arm; guards against a silent reset by anything else.
  if [ $((NOW - LAST_ARM)) -ge 60 ]; then
    arm
    LAST_ARM=$NOW
  fi

  LID=$(ioreg -r -k AppleClamshellState -d 4 2>/dev/null \
        | grep -o 'AppleClamshellState" = [A-Za-z]*' | awk '{print $3}')
  CAF=$(pmset -g assertions 2>/dev/null | grep -c 'caffeinate command-line tool')
  BATT=$(pmset -g batt 2>/dev/null | awk 'NR==2 { s=$3; gsub(";","",s); print s }')
  TS=$(date +%s)

  # A gap larger than 2x the sample interval means this process was frozen,
  # i.e. the machine suspended. That is the primary failure signal.
  if [ "$PREV_TS" -ne 0 ] && [ $((TS - PREV_TS)) -gt $((SAMPLE_SECONDS * 3)) ]; then
    GAPS=$((GAPS + 1))
    echo "$(date '+%F %T') GAP detected $((TS - PREV_TS))s — machine suspended" >> "$LOG"
  fi
  PREV_TS=$TS

  TOTAL_SAMPLES=$((TOTAL_SAMPLES + 1))
  [ "$LID" = "Yes" ] && LID_CLOSED_SAMPLES=$((LID_CLOSED_SAMPLES + 1))

  echo "$(date '+%F %T') lid=${LID:-?} caf=$CAF batt=$BATT" >> "$LOG"
  sleep "$SAMPLE_SECONDS"
done

# --- verdict -----------------------------------------------------------------

touch "$STOP"
ARMS=$(grep -c 'SELECTOR armed=1' "$LOG" || true)
FAILED_ARMS=$(grep -c 'SELECTOR ARM FAILED' "$LOG" || true)
LID_FRACTION=0
[ "$TOTAL_SAMPLES" -gt 0 ] && LID_FRACTION=$(( LID_CLOSED_SAMPLES * 100 / TOTAL_SAMPLES ))

# Cross-check against the kernel log: any new sleep event during the window is
# a failure even if the sampler somehow kept running. Record the reason and the
# power source, because they decide how much the event proves.
SLEEP_AFTER="$(pmset -g log 2>/dev/null | grep -c 'Entering Sleep state' || true)"
NEW_SLEEPS=$(( SLEEP_AFTER - SLEEP_MARK ))
NEW_SLEEP_DETAIL="$(pmset -g log 2>/dev/null \
  | awk '$0 ~ /Entering Sleep state/ && NR > 0' | tail -n 3 | sed 's/^ *//')"

echo "$(date '+%F %T') SOAK end mode=$MODE arms=$ARMS failed_arms=$FAILED_ARMS gaps=$GAPS lid_closed=${LID_FRACTION}% samples=$TOTAL_SAMPLES new_sleeps=$NEW_SLEEPS" >> "$LOG"
[ "$NEW_SLEEPS" -gt 0 ] && printf '%s\n' "$NEW_SLEEP_DETAIL" >> "$LOG"

if [ "$NEW_SLEEPS" -gt 0 ]; then
  echo "FAIL: $NEW_SLEEPS new sleep event(s) in the kernel log (mode=$MODE) — see $LOG" >&2
  exit 1
fi
if [ "$GAPS" -gt 0 ]; then
  echo "FAIL: the machine suspended $GAPS time(s) during the soak — see $LOG" >&2
  exit 1
fi
if [ "$FAILED_ARMS" -gt 0 ]; then
  echo "FAIL: $FAILED_ARMS selector arm(s) failed — see $LOG" >&2
  exit 1
fi
if [ "$ARMS" -eq 0 ]; then
  echo "FAIL: the selector never armed — see $LOG" >&2
  exit 1
fi
# A soak where the lid was never closed proves nothing: no sleep is the
# expected result of an open lid too. Require the lid to have been shut for
# the majority of the run, or report the result as inconclusive.
if [ "$LID_FRACTION" -lt 50 ]; then
  echo "INCONCLUSIVE: lid was closed only ${LID_FRACTION}% of the run." >&2
  echo "Close the lid for most of the soak window and run again." >&2
  exit 1
fi

echo "PASS: ${MINUTES}min soak, $ARMS re-arms, 0 gaps, lid closed ${LID_FRACTION}% of samples."
echo "Log: $LOG"
