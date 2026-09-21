# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile — RUST target (cargo / cargo-fuzz). Builds ON TOP of the
# org C/C++ base (ghcr.io/savantenvs/base), adding a pinned Rust nightly +
# cargo-fuzz under /opt/toolchains/rust, then runs the per-repo mayhem/build.sh.
#
# See SPEC §6.2 items 8/9 and §6.5: the cargo registry cache lives at a FIXED,
# $HOME-independent CARGO_HOME so the air-gapped PATCH re-run resolves crates from it.
#
# Build (from the repo root, on the `mayhem` branch):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] -t rust-lightning-commit:test .

FROM ghcr.io/savantenvs/base:20260621

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (never an ENV — an empty ENV breaks clang). build.sh unsets it when empty.
ARG SOURCE_DATE_EPOCH
# Undefaulted (no '=') so the base ENV default flows through unless --build-arg overrides it.
ARG SANITIZER_FLAGS

# ── Rust toolchain @ a FIXED, lockable, $HOME-independent prefix ───────────────
# Pin the channel by DATE: -Zsanitizer=address (the OSS-Fuzz Rust ASan path) needs
# nightly, and a dated nightly keeps the build reproducible. rust-lightning's MSRV is
# 1.75, but the fuzz crates resolve floating deps, so track a recent nightly.
ARG RUST_CHANNEL=nightly-2026-09-01
ARG CARGO_FUZZ_VERSION=0.13.2

ENV RUSTUP_HOME=/opt/toolchains/rust/rustup \
    CARGO_HOME=/opt/toolchains/rust/cargo \
    PATH=/opt/toolchains/rust/cargo/bin:${PATH}

USER root
RUN install -d /opt/toolchains/rust \
 && curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs -o /tmp/rustup-init.sh \
 && sh /tmp/rustup-init.sh -y --no-modify-path --profile minimal \
        --default-toolchain "${RUST_CHANNEL}" \
 && rustup component add rust-src --toolchain "${RUST_CHANNEL}" \
 && cargo install cargo-fuzz --version "${CARGO_FUZZ_VERSION}" --locked \
 && rm -f /tmp/rustup-init.sh \
 # The commit build AND the air-gapped PATCH re-run run as `mayhem` (2000): it must
 # read the toolchain and read/refresh the cargo registry cache, so hand the whole
 # prefix to 2000.
 && chown -R 2000:2000 /opt/toolchains/rust

# DWARF < 4 anchor (§6.2 item 10): -Zsanitizer=address links librustc-nightly_rt.asan.a
# (DWARF-5) first; verify-repo reads the first CU version. Prepend a DWARF-3 object via the linker wrapper.
RUN install -d /opt/mayhem-dwarf3-anchor \
 && printf 'void __mayhem_dwarf3_anchor(void) {}\n' > /opt/mayhem-dwarf3-anchor/anchor.c \
 && clang -g -gdwarf-3 -c -o /opt/mayhem-dwarf3-anchor/anchor.o /opt/mayhem-dwarf3-anchor/anchor.c \
 && printf '#!/bin/sh\nexec cc /opt/mayhem-dwarf3-anchor/anchor.o "$@"\n' > /opt/mayhem-dwarf3-anchor/cc-wrapper.sh \
 && chmod 755 /opt/mayhem-dwarf3-anchor/cc-wrapper.sh

# Source enters from the build CONTEXT (CI checkout): the FULL repo (incl. .git) → /mayhem.
USER mayhem
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

# Populates $CARGO_HOME (online, this first build) and builds the sanitized fuzz target(s) + tests.
RUN bash mayhem/build.sh

# Run the project's functional suite at build time (a failing suite fails the build).
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
