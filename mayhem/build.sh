#!/usr/bin/env bash
#
# mayhem/build.sh — build rust-lightning's fuzz targets as sanitized libFuzzer
# binaries (OSS-Fuzz Rust path: cargo-fuzz + ASan via RUSTFLAGS), plus the
# project's own functional test suite (normal flags) so mayhem/test.sh can RUN it.
#
# Runs inside the commit image (RUST mayhem/Dockerfile) as `mayhem` in /mayhem.
# The Rust toolchain + cargo registry live at $CARGO_HOME=/opt/toolchains/rust/cargo
# (pinned by the Dockerfile ENV — absolute, $HOME-independent).
#
# UPSTREAM'S OWN FUZZ CRATES ARE USED AS-IS (no additive mayhem/fuzz/ crate):
# rust-lightning already ships a cargo-fuzz-compatible layout — `[package.metadata]
# cargo-fuzz = true` plus a `libfuzzer_fuzz` feature wiring libfuzzer-sys 0.4 — split
# over TWO crates that must be built with DIFFERENT cfgs (see fuzz/src/bin/gen_target.sh
# and the `compile_error!` guards in fuzz/src/bin/target_template.txt):
#   fuzz/fuzz-fake-hashes  REQUIRES --cfg hashes_fuzz   (74 targets)
#   fuzz/fuzz-real-hashes  REQUIRES NO  --cfg hashes_fuzz (1 target, chanmon_consistency)
# Both also require --cfg fuzzing --cfg secp256k1_fuzz. Because the cfgs differ, each
# crate gets its OWN CARGO_TARGET_DIR — a shared one would make the two builds evict
# each other's artifacts and defeat the idempotent/air-gapped re-run.
#
# NOTE: the targets live in `src/bin/*.rs`, not the cargo-fuzz default `fuzz_targets/`.
# `cargo fuzz list` therefore returns nothing, but `cargo fuzz build` (which drives
# `cargo build --bins`) works fine — so we enumerate the targets from src/bin ourselves.
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs THIS script OFFLINE.
#   - This FIRST build (in CI, online) populates the cargo registry under $CARGO_HOME
#     and writes the Cargo.lock files (upstream .gitignore's them, so they are resolved
#     here once and then persist in the image — the offline re-run reuses that exact
#     resolution).
#   - The PATCH re-run resolves crates from that cache. The rlenv runtime exports
#     CARGO_NET_OFFLINE=true for the re-run; we do NOT hard-code --offline here (it
#     would break this first, online build). Re-running on an already-built tree is
#     idempotent (cargo/cargo-fuzz skip up-to-date artifacts).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
# cargo-fuzz has no --jobs flag; cargo reads parallelism from CARGO_BUILD_JOBS.
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

# Incremental compilation is ON by default for the dev/test profile and buys nothing in a
# one-shot container build — it only leaves a large cache behind. Measured at 2.1 GB in
# target/debug/incremental for the test build alone, so turn it off image-wide.
export CARGO_INCREMENTAL=0

SRC="${SRC:-/mayhem}"
cd "$SRC"

# DWARF < 4 (§6.2 item 10): the fuzz binaries must carry DWARF <= 3 debug info so
# Mayhem's triage / ASan backtraces resolve source lines (Mayhem can't read DWARF >= 4).
# `-Zdwarf-version=3` is a nightly rustc flag (the image toolchain is nightly); the
# -Clinker wrapper prepends a DWARF-3 anchor object so the FIRST CU is version 3 even
# though -Zsanitizer=address links the DWARF-5 ASan runtime.
#
# TWO size levers are needed here, because this repo ships 75 targets and each one
# statically links the whole of lightning + secp256k1 + the ASan runtime. Measured on
# msg_ping_target (.text is only 1.3 MB in every case — it is ALL debug info):
#   -Cdebuginfo=2 (the contract default)   475 MB/binary  -> ~35 GB of binaries
#   -Cdebuginfo=1 (limited)                181 MB/binary  -> ~13 GB
#   -Cdebuginfo=1 + compressed DWARF        ~27 MB/binary -> ~2 GB   <- what we ship
# So: `=1` rather than `=2` (keeps function/line info for backtraces, drops the
# variable/type DIEs and .debug_loc that dominate full DWARF), plus zlib-compressed
# debug sections. Compression is done by the LINKER, not a post-pass, so the build
# tree shrinks too and the /mayhem hardlinks below cost nothing. llvm-dwarfdump reads
# SHF_COMPRESSED sections transparently, so the §6.2 item 10 DWARF-version check and
# Mayhem's triage still resolve source lines (verified: 148.9 MB -> 21.9 MB, DWARF
# still reported as version 3, target still fuzzes).
: "${RUST_DEBUG_FLAGS:=-Cdebuginfo=1 -Zdwarf-version=3 -Clink-arg=-Wl,--compress-debug-sections=zlib}"

# Sanitizer selection. The base ENV defaults SANITIZER_FLAGS to ASan+UBSan (clang
# flags rustc ignores), so on the Rust path we translate its INTENT into RUSTFLAGS:
# if SANITIZER_FLAGS requests `address`, build with `-Zsanitizer=address` (the OSS-Fuzz
# Rust ASan path); an EXPLICIT empty SANITIZER_FLAGS (the off-switch, --build-arg
# SANITIZER_FLAGS=) builds a clean, un-instrumented binary. `=` (not `:=`) so an
# explicit empty value is preserved.
: "${CC:=clang}"
: "${SANITIZER_FLAGS=-fsanitize=address,undefined}"
RUST_SAN=""
CARGO_FUZZ_SAN="none"   # cargo-fuzz defaults to address; we drive it explicitly
case "$SANITIZER_FLAGS" in
  *address*) RUST_SAN="-Zsanitizer=address"; CARGO_FUZZ_SAN="address" ;;
esac

# The fuzz workspace sets `lto = true` + `codegen-units = 1`; across 75 binaries that is
# hours of re-optimizing the whole dependency graph per target. Upstream's own ci-fuzz.sh
# strips `lto = true` for exactly this reason — we do the same via the environment so
# upstream's Cargo.toml stays untouched (the port must remain purely additive).
export CARGO_PROFILE_RELEASE_LTO=false
export CARGO_PROFILE_RELEASE_CODEGEN_UNITS=16

TRIPLE="x86_64-unknown-linux-gnu"

# ── LSan off + DWARF-3 anchor, injected via a -Clinker wrapper ────────────────
# Two objects must be prepended to EVERY rustc link:
#   anchor.o     a tiny -gdwarf-3 TU (baked into the image by mayhem/Dockerfile) so the
#                FIRST compile unit is DWARF 3 — -Zsanitizer=address otherwise links the
#                DWARF-5 ASan runtime first and the §6.2 item 10 check reads that.
#   lsan_off.o   mayhem/lsan_off.c's __lsan_is_turned_off() — build-time LSan off-switch
#                (ASan/UBSan stay on and halting). Compiled here, not in the Dockerfile,
#                so the hook lives in the repo where verify-repo can see it wired.
# rustc takes a single -Clinker, so we generate one wrapper that prepends both.
LINK_WRAPPER=""
if [ -n "$RUST_SAN" ]; then
  LSAN_OBJ=/tmp/mayhem-lsan_off.o
  $CC -fPIC $SANITIZER_FLAGS -c "$SRC/mayhem/lsan_off.c" -o "$LSAN_OBJ"
  LINK_WRAPPER=/tmp/mayhem-rustc-link.sh
  printf '#!/bin/sh\nexec cc /opt/mayhem-dwarf3-anchor/anchor.o %s "$@"\n' "$LSAN_OBJ" > "$LINK_WRAPPER"
  chmod 755 "$LINK_WRAPPER"
  LINK_WRAPPER="-Clinker=$LINK_WRAPPER"
fi

# build_fuzz_crate <crate-dir> <target-dir> <extra-cfgs>
# Builds EVERY bin target in the crate, then publishes each to /mayhem/<target>.
build_fuzz_crate() {
  local dir="$1" tgtdir="$2" extra_cfg="$3"

  local names=()
  local f
  for f in "$dir"/src/bin/*.rs; do
    names+=("$(basename "${f%.rs}")")
  done
  [ "${#names[@]}" -gt 0 ] || { echo "ERROR: no fuzz targets under $dir/src/bin/" >&2; exit 1; }

  # shellcheck disable=SC2030
  export RUSTFLAGS="${BASE_RUSTFLAGS:-} $extra_cfg"
  export CARGO_TARGET_DIR="$tgtdir"

  echo "=== cargo fuzz build: $dir (${#names[@]} targets) ==="
  echo "RUSTFLAGS=$RUSTFLAGS"
  echo "CARGO_TARGET_DIR=$CARGO_TARGET_DIR"

  # No target argument => cargo-fuzz builds ALL bins of the crate in ONE cargo
  # invocation, so the dependency graph is compiled once and only the per-target
  # link steps repeat. `--features libfuzzer_fuzz` selects the libfuzzer-sys entry
  # point in fuzz/src/bin/target_template.txt (default is no engine at all).
  cargo fuzz build --fuzz-dir "$dir" --features libfuzzer_fuzz \
        --sanitizer "$CARGO_FUZZ_SAN" -O --debug-assertions

  local t bin
  for t in "${names[@]}"; do
    bin="$tgtdir/$TRIPLE/release/$t"
    [ -x "$bin" ] || { echo "ERROR: expected fuzz binary not found at $bin" >&2; exit 1; }
    # Hardlink rather than copy: these binaries are large and both paths live in the
    # same image layer, so a copy would double the image for no benefit. Fall back to
    # cp if the link cannot be made (e.g. a cross-device build dir).
    ln -f "$bin" "/mayhem/$t" 2>/dev/null || cp -f "$bin" "/mayhem/$t"
    echo "built /mayhem/$t"
  done
}

# Shared flags for both crates. --cfg fuzzing matches libfuzzer-sys; secp256k1_fuzz
# swaps in the fuzzing-friendly secp256k1 shims (both are declared in the crates'
# `check-cfg` lists, which are `forbid`-level — do not invent new cfgs here).
# force-frame-pointers aids ASan backtraces.
BASE_RUSTFLAGS="${RUSTFLAGS:-} --cfg fuzzing --cfg secp256k1_fuzz ${RUST_SAN} -Cforce-frame-pointers ${RUST_DEBUG_FLAGS} ${LINK_WRAPPER}"

build_fuzz_crate fuzz/fuzz-fake-hashes "$SRC/fuzz/target-fake-hashes" "--cfg hashes_fuzz"
build_fuzz_crate fuzz/fuzz-real-hashes "$SRC/fuzz/target-real-hashes" ""

# ── Functional test suite (oracle for PATCH) ──────────────────────────────────
# Build the project's OWN tests with the project's NORMAL flags (a clean, NON-
# sanitized build — NOT the fuzz RUSTFLAGS, and NOT the fuzz target dir) so
# mayhem/test.sh only RUNS them. See mayhem/test.sh for the choice of crates.
# Keep this list in sync with mayhem/test.sh — build.sh compiles, test.sh runs.
TEST_PKGS=(-p lightning -p lightning-invoice -p lightning-types
           -p lightning-rapid-gossip-sync -p lightning-persister)

echo "=== building functional test suite (normal flags) ==="
env -u RUSTFLAGS -u CARGO_TARGET_DIR -u CARGO_PROFILE_RELEASE_LTO -u CARGO_PROFILE_RELEASE_CODEGEN_UNITS \
    cargo test --no-run "${TEST_PKGS[@]}"

echo "build.sh complete"
