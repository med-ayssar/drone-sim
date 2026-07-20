#!/usr/bin/env bash
# Update the services/PX4-Autopilot submodule and install its host build dependencies
# (Gazebo, OpenCV, kconfiglib, empy, ...) using PX4's own OS-specific installer.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

# PX4-Autopilot has huge history and many nested submodules; a full-depth fetch
# over a flaky link often dies with "fetch-pack: invalid index-pack" / early EOF.
# Force HTTP/1.1 + a large buffer (these -c flags propagate to the nested fetches),
# retry a few times, and allow an opt-in shallow fetch that only pulls the pinned
# commits (PX4_SHALLOW=1) - far less data, so it survives unstable connections.
DEPTH_ARGS=()
if [ "${PX4_SHALLOW:-0}" = "1" ]; then
  echo "==> PX4_SHALLOW=1: fetching submodules shallow (--depth 1)."
  DEPTH_ARGS=(--depth 1)
fi

echo "==> Updating services/PX4-Autopilot submodule (recursive)..."
attempt=1
max_attempts=3
until git \
        -c http.version=HTTP/1.1 \
        -c http.postBuffer=524288000 \
        -c core.compression=0 \
        submodule update --init --recursive --jobs 4 \
        ${DEPTH_ARGS[@]+"${DEPTH_ARGS[@]}"} \
        services/PX4-Autopilot; do
  if [ "$attempt" -ge "$max_attempts" ]; then
    echo "ERROR: submodule fetch failed after $max_attempts attempts." >&2
    echo "       Retry with a shallow fetch:  PX4_SHALLOW=1 ./setup.sh" >&2
    exit 1
  fi
  echo "==> Fetch failed (attempt $attempt/$max_attempts) - retrying..." >&2
  attempt=$((attempt + 1))
done

if [ ! -f "services/PX4-Autopilot/Tools/setup/ubuntu.sh" ]; then
  echo "ERROR: services/PX4-Autopilot is not populated - is it a registered submodule?" >&2
  exit 1
fi

OS="$(uname -s)"
case "$OS" in
  Linux)
    echo "==> Detected Linux - running PX4 Ubuntu setup (SITL only, no NuttX)..."
    bash ./services/PX4-Autopilot/Tools/setup/ubuntu.sh --no-nuttx
    ;;
  Darwin)
    echo "==> Detected macOS - running PX4 macOS setup..."
    bash ./services/PX4-Autopilot/Tools/setup/macos.sh
    ;;
  *)
    echo "ERROR: Unsupported OS '$OS' (expected Linux or Darwin)." >&2
    exit 1
    ;;
esac

echo ""
echo "==> PX4 host dependencies installed."
echo "    Build + run SITL:  cd services/PX4-Autopilot && make px4_sitl gz_x500"
echo "    (headless on WSL:   make px4_sitl gz_x500 HEADLESS=1)"
