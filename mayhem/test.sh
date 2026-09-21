#!/usr/bin/env bash
#
# mayhem/test.sh — RUN rust-lightning's OWN functional test suite (already built by
# mayhem/build.sh with the project's NORMAL flags). exit 0 = pass.
#
# Oracle: the `lightning` crate's unit + functional tests are the project's real
# assertion suite — BOLT message ser/deser round-trips, the channel state machine,
# onion construction/failure handling, the router, and the gossip network graph —
# i.e. exactly the code the 75 fuzz targets drive. They assert BEHAVIOR/OUTPUT
# (known-answer vectors, asserted values, expected error variants), so a no-op /
# neutered binary produces the wrong results and FAILS here (anti-reward-hack,
# SPEC §6.3). lightning-invoice / -types / -rapid-gossip-sync / -persister are
# included because the bolt11_deser, invoice_deser, feature_flags,
# process_network_graph and fs_store targets live in those crates.
#
# ~1729 tests across 11 test binaries, ~45s. Emits a CTRF (ctrf.io) summary.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
SRC="${SRC:-/mayhem}"
cd "$SRC"

# MUST match mayhem/build.sh. CARGO_INCREMENTAL is part of the rustc command line and
# therefore part of cargo's unit fingerprint: if build.sh compiles the suite with it set
# to 0 and this script leaves it at the default, cargo considers every unit stale and
# RECOMPILES the whole thing here — which both violates the "test.sh never compiles"
# contract and leaves a second set of artifacts (measured: +1.4 GB of duplicate rlibs
# plus a 2.0 GB incremental cache) baked into the image.
export CARGO_INCREMENTAL=0

# Keep in sync with mayhem/build.sh's TEST_PKGS (build.sh compiles, this only runs).
TEST_PKGS=(-p lightning -p lightning-invoice -p lightning-types
           -p lightning-rapid-gossip-sync -p lightning-persister)

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

# RUN the pre-built suite (build.sh already compiled it; --no-fail-fast to see all
# results). Do NOT compile with the fuzz sanitizer flags — clear RUSTFLAGS and the
# fuzz CARGO_TARGET_DIR/profile overrides so this stays the project's honest
# normal-flag oracle and reuses build.sh's artifacts rather than rebuilding.
LOG="$(mktemp)"
env -u RUSTFLAGS -u CARGO_TARGET_DIR -u CARGO_PROFILE_RELEASE_LTO -u CARGO_PROFILE_RELEASE_CODEGEN_UNITS \
    cargo test "${TEST_PKGS[@]}" --no-fail-fast -- --test-threads="$MAYHEM_JOBS" 2>&1 | tee "$LOG"
run_rc="${PIPESTATUS[0]}"

# cargo prints one "test result: ok. N passed; M failed; K ignored; ..." line per test
# binary (unit + doc). Sum them across all binaries for the aggregate counts.
passed=$(grep -oE 'test result: [a-zA-Z]+\. [0-9]+ passed' "$LOG" | grep -oE '[0-9]+ passed' | awk '{s+=$1} END{print s+0}')
failed=$(grep -oE '[0-9]+ failed' "$LOG" | awk '{s+=$1} END{print s+0}')
ignored=$(grep -oE '[0-9]+ ignored' "$LOG" | awk '{s+=$1} END{print s+0}')
had_results=0
grep -qE '^test result:' "$LOG" && had_results=1
rm -f "$LOG"

# Guard: if cargo itself failed (compile error / runner missing) but reported no test
# result lines, surface that as a failure rather than a spurious pass.
if [ "$run_rc" -ne 0 ] && [ "$failed" -eq 0 ] && [ "$passed" -eq 0 ]; then
  failed=1
fi
# Anti-reward-hack: a neutered/no-op binary (SPEC §6.3 sabotage check LD_PRELOADs an
# _exit(0) constructor) produces NO 'test result:' lines at all — that must FAIL, not
# silently report "0 tests, 0 failures".
if [ "$had_results" -eq 0 ] && [ "$passed" -eq 0 ] && [ "$failed" -eq 0 ]; then
  echo "ERROR: no 'test result:' lines — test runner did not execute (build.sh bug or neutered binary)" >&2
  emit_ctrf "cargo-test-lightning" 0 1 0
  exit 1
fi

emit_ctrf "cargo-test-lightning" "$passed" "$failed" "$ignored"
