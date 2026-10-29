#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# Upstream's own unit tests (avahi-common/, avahi-core/), built by build.sh into mayhem/build-test.
# GOLDEN: deterministic output, compared (address-normalised) against mayhem/test-golden/expected.sha256,
#         so a program that exits 0 without doing the work fails.
# ASSERT: tests that verify purely through assert() (and have no stable output); exit status only.
BT="$SRC/mayhem/build-test"
GOLDEN_FILE="$SRC/mayhem/test-golden/expected.sha256"
GOLDEN="avahi-common/strlst-test avahi-common/domain-test avahi-common/timeval-test avahi-common/alternative-test avahi-core/dns-test avahi-core/hashmap-test"
ASSERT="avahi-common/utf8-test avahi-core/iface-test avahi-core/dns-spin-test avahi-core/prioq-test"

OUT="$(mktemp)"
run_test() {  # runs one test; sets RC; leaves its address-normalised output in $OUT
  ( cd "$BT" && timeout 120 "./$1" ) >"$OUT" 2>&1; RC=$?
  sed -i 's/0x[0-9a-f]\+/0xADDR/g' "$OUT"
}

passed=0; failed=0
[ -d "$BT" ] || { echo "missing $BT: mayhem/build.sh did not build the tests" >&2; emit_ctrf avahi-unit-tests 0 1; exit 1; }
for t in $GOLDEN; do
  [ -x "$BT/$t" ] || { echo "FAIL $t: binary missing" >&2; failed=$((failed+1)); continue; }
  run_test "$t"; got="$(sha256sum <"$OUT" | cut -d' ' -f1)"
  want="$(awk -v n="$t" '$2==n {print $1}' "$GOLDEN_FILE")"
  if [ "$RC" -eq 0 ] && [ -n "$want" ] && [ "$got" = "$want" ]; then
    echo "PASS $t"; passed=$((passed+1))
  else
    echo "FAIL $t (rc=$RC got=$got want=$want)" >&2; failed=$((failed+1))
  fi
done
for t in $ASSERT; do
  [ -x "$BT/$t" ] || { echo "FAIL $t: binary missing" >&2; failed=$((failed+1)); continue; }
  run_test "$t"
  if [ "$RC" -eq 0 ]; then echo "PASS $t"; passed=$((passed+1)); else echo "FAIL $t (rc=$RC)" >&2; failed=$((failed+1)); fi
done

emit_ctrf avahi-unit-tests "$passed" "$failed" 0
