# Builds Moorland's single-file releases from any machine with Docker,
# including Windows, which Burrito cannot build on directly.
#
#   docker build -t moorland-release release/
#   docker run --rm -v "$PWD:/app" -v moorland-build:/build \
#     -e BURRITO_TARGET=windows -e TARGET_OS=windows -e TARGET_ARCH=x86_64 -e TARGET_ABI=msvc \
#     moorland-release
#
# Targets and their TARGET_* values (the SQLite native library is fetched
# precompiled for that target):
#   windows    windows / x86_64  / msvc
#   linux      linux   / x86_64  / gnu
#   macos      apple   / x86_64  / darwin
#   macos_arm  apple   / aarch64 / darwin
#
# Output lands in burrito_out/ inside the project. Dependencies and build
# artefacts stay in the moorland-build volume so they never mix with a
# native checkout's _build and deps.

FROM hexpm/elixir:1.18.4-erlang-27.3.4-debian-bookworm-20260610-slim

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    build-essential ca-certificates curl git p7zip-full xz-utils \
  && rm -rf /var/lib/apt/lists/*

# Burrito pins the exact Zig version it builds its wrapper with (its README
# lags; the check lives in Burrito.check_zig_version/0).
ARG ZIG_VERSION=0.16.0
RUN curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
  | tar -xJ -C /opt \
  && ln -s "/opt/zig-x86_64-linux-${ZIG_VERSION}/zig" /usr/local/bin/zig

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod \
    MIX_BUILD_ROOT=/build/_build \
    MIX_DEPS_PATH=/build/deps \
    HEX_HOME=/build/hex

WORKDIR /app

# Compile everything first, then recompile exqlite alone so a reused build
# volume picks up the native library for this run's target.
CMD ["sh", "-c", "mix deps.get --only prod && mix deps.compile && mix deps.compile exqlite --force && mix assets.deploy && mix release moorland --overwrite"]
