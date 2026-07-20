# drone-sim

PX4 SITL + ROS 2 (Humble) development environment, wired together with Nix.

The stack has four moving parts:

1. **PX4-Autopilot** (git submodule) — the flight stack, run as SITL with Gazebo. Built on the host, *not* by Nix.
2. **Micro XRCE-DDS Agent** — the bridge that turns PX4's uXRCE-DDS traffic into ROS 2 topics. Provided by the Nix flake.
3. **px4_msgs** — the ROS 2 message definitions PX4 publishes/subscribes. Provided by the Nix flake.
4. **px4_offboard_cpp** — our custom C++ node (`dev/src/px4_offboard_cpp`) that arms the drone and commands a takeoff via offboard control.
5. **QGroundControl** — the ground control station GUI. Optional but handy for visualizing the vehicle, mode, and telemetry. Provided by the Nix flake.

The ROS 2 side talks over **UDP port 8888** (PX4's default uXRCE-DDS port). QGroundControl talks **MAVLink over UDP 14550** and auto-connects to PX4 SITL — the two channels are independent.

---

## 1. Install Nix

Install Nix with flakes enabled. The [Determinate Systems installer](https://github.com/DeterminateSystems/nix-installer) turns flakes on by default:

```bash
curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install
```

If you use the official installer instead, enable flakes manually:

```bash
mkdir -p ~/.config/nix
echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf
```

Restart your shell afterwards so `nix` is on `PATH`.

> **WSL note:** this repo is developed on WSL2. Run all commands from inside the WSL Linux filesystem (e.g. `~/dev/drone-sim`), not a `/mnt/c` path — Gazebo and the build are far slower over the Windows mount.

> **WSL note — build sandbox:** the Micro XRCE-DDS Agent flake's CMake superbuild `git clone`s its dependencies *during the build*. Nix's default Linux build sandbox gives builds a loopback-only network namespace, so on WSL those clones fail with `Could not resolve host: github.com`. Disable the sandbox so builds can use the host network:
>
> ```bash
> echo "sandbox = false" >> ~/.config/nix/nix.conf
> ```
>
> For a single-user Nix install (store owned by your user, no `nix-daemon`) this takes effect immediately — no sudo, no restart. If you're on a multi-user/daemon install, put the line in `/etc/nix/nix.conf` (needs root) and restart the daemon: `sudo systemctl restart nix-daemon`. Verify with `nix show-config | grep '^sandbox '`. This makes builds impure (they can reach the network); it's the same tradeoff a default native-Linux Nix setup already makes.

> **Corporate network note — TLS-inspection proxy (e.g. Zscaler):** the agent's build git-clones its dependencies. If your network runs a TLS-inspecting proxy, `github.com` is served with a certificate re-signed by the proxy's **own root CA**, which isn't in the standard public bundle — the clones then fail with `unable to get local issuer certificate`. The build's CA is **opt-in**: point `MICRO_XRCE_EXTRA_CACERT` at the proxy's root CA (an absolute path; typically already installed on your host at `/etc/ssl/certs/`) and build with `--impure`:
>
> ```bash
> # find your proxy root CA, e.g.:
> ls /usr/local/share/ca-certificates /etc/ssl/certs | grep -i zscaler
>
> MICRO_XRCE_EXTRA_CACERT=/etc/ssl/certs/zscaler.pem nix build --impure .#micro-xrce-dds-agent
> ```
>
> `./start.sh` reads the same variable and automatically threads it (plus `--impure`) into its `nix develop` panes:
>
> ```bash
> MICRO_XRCE_EXTRA_CACERT=/etc/ssl/certs/zscaler.pem ./start.sh
> ```
>
> On a private PC with no such proxy, leave it unset — the plain public CA bundle works and no `--impure` is needed.

---

## 2. Clone and set up PX4-Autopilot

`setup.sh` initializes the PX4 submodule and installs PX4's host build dependencies (Gazebo, OpenCV, empy, kconfiglib, …) using PX4's own OS-specific installer. It builds **SITL only** (no NuttX firmware).

```bash
git clone <this-repo-url> drone-sim
cd drone-sim
./setup.sh
```

This fetches the PX4 submodule (recursively), then runs the matching PX4 installer for your OS (Ubuntu/Linux or macOS). Expect it to take a while and to pull in a lot of apt packages on first run.

PX4-Autopilot has a large history, so on a slow or unstable connection the full-depth fetch can fail with `fetch-pack: invalid index-pack` / `early EOF`. `setup.sh` already forces HTTP/1.1, a large transfer buffer, and retries automatically. If it still fails, do a **shallow** fetch — only the pinned commits, far less data:

```bash
PX4_SHALLOW=1 ./setup.sh
```

Shallow trees build SITL fine; they just report a generic PX4 version string (no git tags). Harmless for development.

---

## 3. Enter the Nix dev shell

The dev shell puts ROS 2 Humble, the DDS agent, `px4_msgs`, `colcon`, `tmux`, and QGroundControl on your `PATH`.

```bash
nix develop
```

On entry it prints a short cheat-sheet and defines a `start-agent` alias. It also sets `ROS_DOMAIN_ID=0`.

> **Behind a corporate TLS-inspection proxy (e.g. Zscaler):** the dev shell builds the agent, whose git clones need the proxy's root CA. Export `MICRO_XRCE_EXTRA_CACERT` (an absolute path to that CA) and enter the shell with `--impure`:
>
> ```bash
> export MICRO_XRCE_EXTRA_CACERT=/etc/ssl/certs/zscaler.pem
> nix develop --impure
> ```
>
> `--impure` is required (the CA path is read via `builtins.getEnv`, which is empty in a pure evaluation). On a private PC with no such proxy, plain `nix develop` works. See the corporate network note in Section 1 for details.

> Run **every command in the sections below from inside `nix develop`**. Open new terminals with `nix develop` each, or use `tmux` (bundled in the shell) to split panes.

---

## 4. Build PX4 SITL and launch the simulation

From the repo root, inside the dev shell:

```bash
cd services/PX4-Autopilot
make px4_sitl gz_x500
```

Headless (recommended on WSL, no GUI):

```bash
make px4_sitl gz_x500 HEADLESS=1
```

PX4 boots the `x500` quadcopter in Gazebo and automatically starts its `uxrce_dds_client`, which connects to the agent on **UDP 8888**. Leave this running.

---

## 5. Start the Micro XRCE-DDS Agent

In a **second** terminal (also inside `nix develop`), start the agent listening on UDP 8888:

```bash
MicroXRCEAgent udp4 -p 8888
# or the shortcut the dev shell defines:
start-agent
```

Once PX4 and the agent are both up, PX4's topics appear on the ROS 2 graph. Verify from any dev-shell terminal:

```bash
ros2 topic list | grep fmu
```

You should see `/fmu/in/*` (commands into PX4) and `/fmu/out/*` (state out of PX4).

> The `udp4 -p 8888` is the important part — it must match PX4's client port. If the topics never appear, this mismatch is the first thing to check.

---

## 6. Build and run the custom C++ node

Our node lives in the ROS 2 workspace under `dev/`. Build it with `colcon` from the `dev/` directory:

```bash
cd dev
colcon build --packages-select px4_offboard_cpp
source install/setup.bash
```

Then run it in a **third** terminal (dev shell + the `source` above):

```bash
ros2 run px4_offboard_cpp offboard_control
```

What it does (`dev/src/px4_offboard_cpp/src/offboard_control.cpp`):

1. Streams `OffboardControlMode` + `TrajectorySetpoint` at 10 Hz.
2. After 10 setpoints, requests **Offboard** mode and **arms**.
3. Commands a takeoff to 5 m (PX4 uses NED, so `z = -5`).
4. Subscribes to `/fmu/out/vehicle_local_position` and `/fmu/out/vehicle_status` and logs `armed / nav_state / altitude` roughly every 2 s.

Watch the log lines — altitude should climb toward 5.0 m once armed.

### Useful build variants

```bash
# Debug build (full symbols, no optimization)
colcon build --packages-select px4_offboard_cpp --cmake-args -DCMAKE_BUILD_TYPE=Debug

# Address/UB sanitizer build
colcon build --packages-select px4_offboard_cpp --cmake-args -DENABLE_ASAN=ON
```

---

## 7. (Optional) Launch QGroundControl

QGroundControl is bundled in the dev shell. In any dev-shell terminal:

```bash
QGroundControl
# or the shortcut the dev shell defines:
start-qgc
```

It listens for MAVLink on **UDP 14550** and auto-connects to a running PX4 SITL — no configuration needed. Use it to watch the vehicle on the map, see the flight mode / arming state, and confirm your offboard node's takeoff visually.

> **WSL note:** QGroundControl is a Qt GUI, so it needs a display. WSLg (Windows 11) provides one out of the box; on older setups you'll need an X server. It runs independently of the ROS 2 / DDS side — you can use it with or without the agent and custom node.
>
> **WSL note — `Could not initialize GLX` / `Aborted (core dumped)`:** WSLg's Xwayland can't provide the OpenGL FBConfig Qt wants, so QGC crashes on startup under the default X11 path. Run it on Wayland with Mesa's software EGL instead. `./start.sh` does this automatically on WSL; to launch QGC standalone:
>
> ```bash
> MESA=$(nix build --no-link --print-out-paths nixpkgs#mesa)
> GLVND=$(nix build --no-link --print-out-paths nixpkgs#libglvnd)
> QT_QPA_PLATFORM=wayland LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe \
>   LD_LIBRARY_PATH="$GLVND/lib:$MESA/lib" QGroundControl
> ```

> **macOS note:** nixpkgs only ships a Linux build of QGroundControl, so the dev shell omits it on Darwin. Install the official [QGroundControl `.dmg`](https://docs.qgroundcontrol.com/master/en/qgc-user-guide/getting_started/download_and_install.html) instead — it connects to PX4 SITL over UDP 14550 the same way.

---

## One-command startup

`start.sh` launches the whole stack in a 3-pane `tmux` session so you don't have to juggle terminals:

- **pane 0** — PX4 SITL + Gazebo (host)
- **pane 1** — the DDS agent inside `nix develop` on UDP 8888
- **pane 2** — builds and runs the custom C++ node inside `nix develop`

```bash
./start.sh              # Gazebo GUI
HEADLESS=1 ./start.sh   # headless Gazebo (recommended on WSL)
```

It installs/provides tmux automatically (via `nix shell nixpkgs#tmux` if it isn't already on `PATH`), and re-attaches to the existing `drone-sim` session instead of starting duplicates. Detach with `Ctrl-b d`; tear down with `tmux kill-session -t drone-sim`. QGroundControl (Section 7) is intentionally left out — start it separately when you want the GUI.

---

## Quick reference

| Step | Command | Where |
|------|---------|-------|
| Enter env | `nix develop` | repo root |
| PX4 SITL | `cd services/PX4-Autopilot && make px4_sitl gz_x500 HEADLESS=1` | terminal 1 |
| Agent | `start-agent` (`MicroXRCEAgent udp4 -p 8888`) | terminal 2 |
| Build node | `cd dev && colcon build --packages-select px4_offboard_cpp && source install/setup.bash` | terminal 3 |
| Run node | `ros2 run px4_offboard_cpp offboard_control` | terminal 3 |
| QGroundControl | `start-qgc` (`QGroundControl`) | terminal 4 (optional) |

**Startup order:** PX4 SITL → agent → your node. PX4 and the agent will retry the connection, but the node needs both up before it can see the `/fmu/*` topics.

---

## Troubleshooting

- **No `/fmu/*` topics** — agent not on port 8888, or PX4 SITL not running. Confirm both, then `ros2 topic list`.
- **Node sees no state / never arms** — QoS mismatch. PX4 publishes best-effort; the node already matches this. Make sure `ROS_DOMAIN_ID` is `0` in every terminal (the dev shell sets it).
- **`px4_msgs` not found at build** — you're outside `nix develop`. Re-enter the shell so the flake-provided `px4_msgs` is on the CMake prefix path.
- **Gazebo slow / crashes on WSL** — use `HEADLESS=1`, and work from the native Linux filesystem, not `/mnt/c`.
- **Submodule fetch fails (`invalid index-pack` / `early EOF`)** — the PX4 history is too big for a flaky link. `setup.sh` retries with HTTP/1.1 + a large buffer; if it still dies, run `PX4_SHALLOW=1 ./setup.sh` to fetch only the pinned commits.
- **Nix build fails with `Could not resolve host: github.com` (WSL)** — the build sandbox has no network, so the agent's CMake superbuild can't clone its deps. Add `sandbox = false` to `~/.config/nix/nix.conf` (see the WSL sandbox note in Section 1).
- **Nix build fails with `unable to get local issuer certificate` (corporate network)** — a TLS-inspection proxy (e.g. Zscaler) is re-signing GitHub's cert with a root CA the build doesn't trust. Set `MICRO_XRCE_EXTRA_CACERT` to your proxy's root CA and build with `--impure` (see the corporate network note in Section 1). `./start.sh` picks up the same variable.
