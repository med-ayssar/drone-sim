#!/usr/bin/env bash
# Launch the full stack in a tmux session, one tab (window) per component:
#   tab 0  px4    PX4 SITL + Gazebo       (host toolchain, built by ./setup.sh)
#   tab 1  agent  Micro XRCE-DDS Agent    (Nix dev shell, UDP 8888)
#   tab 2  node   custom C++ node         (nix: colcon build + ros2 run)
#   tab 3  qgc    QGroundControl (Linux)  (Nix dev shell; MAVLink UDP 14550)
#
# Switch tabs with Ctrl-b <number> or Ctrl-b n / Ctrl-b p.
#
# Usage:
#   ./start.sh              # Gazebo GUI
#   HEADLESS=1 ./start.sh   # headless Gazebo (recommended on WSL)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

SESSION="drone-sim"

# --- Ensure tmux is available -------------------------------------------------
# The dev shell ships tmux, but this script runs on the host before entering it.
# If tmux is missing, re-exec ourselves inside a throwaway Nix shell that provides
# it (this repo already requires Nix). Fall back to a clear error otherwise.
if ! command -v tmux >/dev/null 2>&1; then
  if command -v nix >/dev/null 2>&1; then
    echo "==> tmux not found - relaunching inside 'nix shell nixpkgs#tmux'..."
    exec nix shell nixpkgs#tmux --command "$0" "$@"
  fi
  echo "ERROR: tmux is not installed and Nix is unavailable to provide it." >&2
  echo "       Install tmux (e.g. 'sudo apt install tmux') and re-run." >&2
  exit 1
fi

# --- Reuse an existing session instead of stacking duplicates -----------------
if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "==> Session '$SESSION' already running - attaching."
  exec tmux attach -t "$SESSION"
fi

# --- Build the PX4 make command (optionally headless) -------------------------
PX4_CMD="make px4_sitl gz_x500"
if [ "${HEADLESS:-0}" = "1" ]; then
  PX4_CMD="$PX4_CMD HEADLESS=1"
fi

# --- Corporate TLS-inspection proxy (e.g. Zscaler) ----------------------------
# The Nix-built Micro XRCE-DDS Agent git-clones its dependencies at build time.
# Behind a TLS-inspecting proxy those clones fail unless the build trusts the
# proxy's root CA. Point MICRO_XRCE_EXTRA_CACERT at that CA (absolute path) and
# we thread it -- plus the required --impure -- into the nix develop panes.
# Unset (e.g. on a private PC) this is a no-op.
NIX_IMPURE=""
NIX_ENV_PREFIX=""
if [ -n "${MICRO_XRCE_EXTRA_CACERT:-}" ]; then
  NIX_IMPURE="--impure"
  NIX_ENV_PREFIX="MICRO_XRCE_EXTRA_CACERT='$MICRO_XRCE_EXTRA_CACERT' "
  echo "==> Using extra CA for agent build: $MICRO_XRCE_EXTRA_CACERT"
fi

# --- Create one tab (window) per component, capturing pane IDs for send-keys --
w0="$(tmux new-session -d -s "$SESSION" -n px4   -c "$ROOT" -P -F '#{pane_id}')"
w1="$(tmux new-window  -t "$SESSION" -n agent -c "$ROOT" -P -F '#{pane_id}')"
w2="$(tmux new-window  -t "$SESSION" -n node  -c "$ROOT" -P -F '#{pane_id}')"

# tab 3 (Linux only): QGroundControl. nixpkgs only packages QGC for Linux, so
# the flake omits it on macOS -- there, install the official .dmg separately.
QGC_PANE=""
if [ "$(uname -s)" = "Linux" ]; then
  QGC_PANE="$(tmux new-window -t "$SESSION" -n qgc -c "$ROOT" -P -F '#{pane_id}')"
fi

# WSLg's Xwayland can't provide the GLX FBConfig Qt wants, so QGC aborts with
# "Could not initialize GLX" under the default X11 path. On WSL, run it on
# Wayland with Mesa's software EGL instead (resolved from nixpkgs for libEGL).
# On a native Linux desktop QGC uses the GPU normally, so we skip the override.
QGC_ENV=""
if [ -n "$QGC_PANE" ] && grep -qiE "microsoft|wsl" /proc/version 2>/dev/null; then
  _mesa="$(nix build --no-link --print-out-paths nixpkgs#mesa 2>/dev/null || true)"
  _glvnd="$(nix build --no-link --print-out-paths nixpkgs#libglvnd 2>/dev/null || true)"
  QGC_ENV="QT_QPA_PLATFORM=wayland LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe LD_LIBRARY_PATH=$_glvnd/lib:$_mesa/lib "
fi

# tab 0 (px4): PX4 SITL + Gazebo (host shell - uses deps from ./setup.sh, NOT Nix)
tmux send-keys -t "$w0" \
  "cd services/PX4-Autopilot && $PX4_CMD" C-m

# tab 1 (agent): DDS agent inside the Nix dev shell, bound to PX4's default UDP port
tmux send-keys -t "$w1" \
  "${NIX_ENV_PREFIX}nix develop $NIX_IMPURE \"$ROOT\" --command MicroXRCEAgent udp4 -p 8888" C-m

# tab 2 (node): build + run our C++ node inside the Nix dev shell
tmux send-keys -t "$w2" \
  "cd dev && ${NIX_ENV_PREFIX}nix develop $NIX_IMPURE \"$ROOT\" --command bash -c 'export ROS_DOMAIN_ID=0; colcon build --packages-select px4_offboard_cpp && source install/setup.bash && ros2 run px4_offboard_cpp offboard_control'" C-m

# tab 3 (qgc): QGroundControl GUI (Linux only). Needs a display -- WSLg provides
# one on Windows 11; on older WSL setups you need an X server. Auto-connects to
# PX4 SITL over MAVLink UDP 14550.
if [ -n "$QGC_PANE" ]; then
  tmux send-keys -t "$QGC_PANE" \
    "${NIX_ENV_PREFIX}nix develop $NIX_IMPURE \"$ROOT\" --command bash -c '${QGC_ENV}QGroundControl'" C-m
fi

tmux select-window -t "$SESSION:px4"
exec tmux attach -t "$SESSION"
