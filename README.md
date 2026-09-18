# isaacsim-runpod

A RunPod-ready Docker template that runs the **NVIDIA Isaac Sim GUI in a web
browser** via **KasmVNC**, on an **XFCE** desktop, with **ROS 2 Humble**
installed and wired into Isaac Sim's ROS 2 bridge.

**Prebuilt image:** [`hrithik108/ubuntu-isaac-sim`](https://hub.docker.com/repository/docker/hrithik108/ubuntu-isaac-sim/general)
on Docker Hub — pull it directly, or build from this repo's `Dockerfile`.

**One-click deploy:** [RunPod template](https://console.runpod.io/deploy?template=tj7pvvjhwl&ref=sa8w351v)
— spins up a pod from the prebuilt image with the right ports already configured.

```
ubuntu:22.04
        └── + Miniforge/conda env `env_isaacsim`
        │        └── Isaac Sim installed via pip (isaacsim[all,extscache])
        └── + VirtualGL             → GPU-accelerated rendering into the VNC framebuffer
        └── + XFCE desktop
        └── + KasmVNC 1.4.0         → browser access on port 6901
        └── + ROS 2 Humble          → ros-base, sourced for the isaacsim ros2 bridge
        └── + VS Code, Google Chrome
```

Unlike the official `nvcr.io/nvidia/isaac-sim` container image, this template
installs Isaac Sim **via pip into an isolated conda env**, so you can swap
Isaac Sim versions later with a single `pip install` — no image rebuild
needed. See [Isaac Sim version / upgrading](#isaac-sim-version--upgrading)
below.

## Files

| File | Purpose |
|------|---------|
| `Dockerfile` | Builds the image (published as `hrithik108/ubuntu-isaac-sim`) |
| `build.sh` | Version-aware build wrapper (`-v`, `--list`, `--push`, `--clean`) |
| `Dockerfile.test` | Lightweight variant for quickly testing image changes |
| `entrypoint.sh` | PID 1 — sets up SSH, starts sshd, configures the KasmVNC password, starts KasmVNC + XFCE |
| `run-isaacsim.sh` | Activates the `env_isaacsim` conda env, sets ROS 2 bridge env vars, launches Isaac Sim through VirtualGL |
| `vnc/xstartup` | Starts the XFCE session inside VNC |
| `vnc/kasmvnc.yaml` | KasmVNC config (SSL off so RunPod's proxy fronts it) |
| `vnc/IsaacSim.desktop` | Desktop launcher icon (runs `run-isaacsim.sh`) |
| `vnc/GoogleChrome.desktop` | Browser launcher icon |
| `vnc/VSCode.desktop` | VS Code launcher icon |
| `vnc/xfwm4.xml` | XFCE window manager config |

## Requirements

- An **RTX-capable NVIDIA GPU** — Isaac Sim's RTX renderer requires ray-tracing
  hardware (RTX A-series, L4/L40, A6000, 3090/4090, etc.). Non-RTX GPUs (T4, V100,
  A100 **without** RTX cores) will not render the viewport.
- NVIDIA Container Toolkit on the host (RunPod provides this).

## Quick start — use the prebuilt image

```bash
docker run --rm --gpus all \
  -e NVIDIA_DRIVER_CAPABILITIES=all \
  -p 6901:6901 \
  -e VNC_PW='choose-a-password' \
  hrithik108/ubuntu-isaac-sim:latest
```

Open `http://localhost:6901/`, log in with user `kasm_user` and your `VNC_PW`,
then double-click the **Isaac Sim** icon on the desktop (or run
`run-isaacsim.sh` in a terminal).

## Build it yourself

`build.sh` is the supported way in. Isaac Sim is pip-installed into a conda env,
so the version is just a build argument — the script maps the Isaac Sim version
to the Python ABI and PyTorch wheel that release actually supports, and refuses
versions NVIDIA does not publish before you spend an hour building:

```bash
./build.sh --list                    # every version on pypi.nvidia.com
./build.sh                           # the default (6.1.0.0)
./build.sh -v 5.1.0.0                # any other release
./build.sh -v 6.1.0.0 --latest --push
./build.sh -v 6.1.0.0 --no-torch     # smaller image, GUI-only
./build.sh --clean -v 6.1.0.0        # prune build cache + dangling images first
```

| Isaac Sim | Python | Default torch |
|---|---|---|
| 6.x | 3.12 | `torch==2.11.0` (cu128) |
| 5.x | 3.11 | `torch==2.7.0` |
| 4.x | 3.10 | `torch==2.5.1` / `2.4.0` |

The Python column is not a preference. Isaac Sim wheels are built for exactly
one CPython ABI (`Requires-Python: ==3.12.*` for 6.x), so a 6.x build on Python
3.11 dies at pip resolve time with a misleading "no matching distribution".

Building by hand works too, as long as you keep the three knobs in sync:

```bash
docker build \
  --build-arg ISAACSIM_PIP_VERSION=5.1.0.0 \
  --build-arg PYTHON_VERSION=3.11 \
  --build-arg TORCH_SPEC=torch==2.7.0 \
  -t hrithik108/ubuntu-isaac-sim:5.1 .
```

| Build arg | Default | Meaning |
|-----------|---------|---------|
| `KASMVNC_VERSION` | `1.4.0` | KasmVNC release to install |
| `ISAACSIM_PIP_VERSION` | `6.1.0.0` | Isaac Sim pip package version (`isaacsim[all,extscache]==<ver>`) |
| `PYTHON_VERSION` | `3.12` | Python version for the `env_isaacsim` conda env — must match the release's ABI |
| `TORCH_SPEC` | `torch==2.11.0` | PyTorch spec installed before Isaac Sim; empty skips it (GUI-only) |
| `TORCH_CUDA_INDEX` | `https://download.pytorch.org/whl/cu128` | pip index used for `TORCH_SPEC` |
| `ROS_PACKAGE` | `ros-humble-ros-base` | ROS 2 package to install |

## Isaac Sim version / upgrading

Because Isaac Sim lives in a pip-installed conda env (`env_isaacsim`) rather
than being baked into the base image, you can swap it **without rebuilding** by
execing into a running container — as long as the new version targets the same
Python ABI (6.x needs 3.12, 5.x needs 3.11):

```bash
conda activate env_isaacsim
pip install "isaacsim[all,extscache]==<new-version>" --extra-index-url https://pypi.nvidia.com
```

Across ABIs, or for a durable upgrade, rebuild: `./build.sh -v <new-version>`.

## Disk space

Each image is ~30 GB and the build cache grows fast. To reclaim safely:

```bash
docker builder prune -af    # build cache
docker image prune -f       # dangling layers only
```

Avoid `docker image prune -a` — it deletes every image not currently attached
to a container, including unrelated ones you still want. `./build.sh --clean`
runs the two safe commands above before building.

## Run locally (to test before RunPod)

```bash
docker run --rm --gpus all \
  -e NVIDIA_DRIVER_CAPABILITIES=all \
  -p 6901:6901 \
  -e VNC_PW='choose-a-password' \
  hrithik108/ubuntu-isaac-sim:latest
```

## Deploy as a RunPod template

**Fastest path:** use the prebuilt template —
[console.runpod.io/deploy?template=tj7pvvjhwl](https://console.runpod.io/deploy?template=tj7pvvjhwl&ref=sa8w351v).
Pick an RTX GPU, set `VNC_PW`, deploy.

To set it up manually instead:

1. **Templates → New Template.**
2. **Container Image:** `hrithik108/ubuntu-isaac-sim:latest`
3. **Expose HTTP Ports:** `6901`  (RunPod proxies it as
   `https://<pod-id>-6901.proxy.runpod.net` and provides TLS — that's why
   KasmVNC runs plain-HTTP internally).
   **Expose TCP Ports:** `22`  (for SSH — RunPod maps it to a public
   `<ip>:<port>`).
4. **Environment variables:**
   | Name | Example | Notes |
   |------|---------|-------|
   | `VNC_PW` | `super-secret` | **Set this** — web login password |
   | `VNC_USER` | `kasm_user` | web login username (default `kasm_user`) |
   | `RESOLUTION` | `1920x1080` | desktop size |
5. Deploy a pod on an **RTX GPU**, wait for it to start, then open the pod's
   **6901** HTTP port from the RunPod UI ("Connect").

## SSH access

The container runs `sshd` on port **22**. RunPod injects your account's SSH
public key(s) via the `PUBLIC_KEY` env var; the entrypoint writes it to
`/root/.ssh/authorized_keys`. Make sure you've added your key under RunPod
**Settings → SSH Public Keys**.

Once the pod is up, connect using the command RunPod shows on the pod's
**Connect** panel — either:

```bash
# Direct TCP (needs the exposed TCP 22 → public ip:port; supports scp/rsync/-L)
ssh root@<public-ip> -p <mapped-port>

# Or RunPod's SSH proxy
ssh <pod-id>-<hash>@ssh.runpod.io -i ~/.ssh/id_ed25519
```

ROS 2 is auto-sourced in the SSH shell too (added to `/root/.bashrc`), and
`conda activate env_isaacsim` puts you in the Isaac Sim Python env.

## Environment variables

| Var | Default | Meaning |
|-----|---------|---------|
| `VNC_PW` | `isaacsim` | KasmVNC web password — **change it** |
| `VNC_USER` | `kasm_user` | KasmVNC web username |
| `RESOLUTION` | `1920x1080` | Desktop resolution |
| `VNC_PORT` | `6901` | KasmVNC web port |
| `PUBLIC_KEY` | *(unset)* | SSH public key installed for `root` (RunPod sets this automatically) |

## Rendering: VirtualGL

Isaac Sim's Vulkan/RTX renderer needs a real GPU render node to draw into, but
KasmVNC's X server is software-only. `run-isaacsim.sh` launches Isaac Sim
through **VirtualGL** (`vglrun -d egl0 isaacsim`), which redirects GPU
rendering to `/dev/dri/renderD128` and blits the result into the VNC
framebuffer. Without VirtualGL the Kit window renders blank over VNC. If no
GPU render node is available, the script falls back to launching Isaac Sim
directly (and warns that the viewport may be blank).

## ROS 2 Humble

The image installs **`ros-humble-ros-base`** (no rviz/VTK) as a *system*
package. This is deliberate: `ros-humble-desktop` pulls rviz + VTK, whose
`libfreetype6-dev` dependency conflicts with the `libfreetype6` shipped in
Isaac Sim's pip wheels and fails to install. ros-base gives you
`rclcpp`/`rclpy`/`ros2` CLI and everything the Isaac Sim ROS 2 bridge needs —
Isaac Sim itself is your visualization.

System ROS 2 is auto-sourced in interactive shells (`~/.bashrc`), but the
`isaacsim.ros2.bridge` extension needs Isaac's **own bundled** ROS 2 Humble
libraries — the system ROS 2 libs have an ABI mismatch with the prebuilt
bridge. `run-isaacsim.sh` therefore points `LD_LIBRARY_PATH` at the bridge's
bundled libs (`isaacsim.ros2.bridge/bin`, `.../humble/lib`,
`omni.usd.libs-*/bin`) **scoped to the Isaac Sim process only** — this is
never registered globally via `ldconfig`, which would break the system `ros2`
CLI (`rclpy` would pick up Isaac's spdlog/fmt and hit an undefined symbol in
`librcl_logging_spdlog.so`).

Verify inside the desktop terminal, after starting the ROS 2 bridge / a
sample in Isaac Sim:

```bash
source /opt/ros/humble/setup.bash
ros2 topic list
```

**Want rviz2 / the full desktop anyway?** Override the build arg — but be
ready to resolve the freetype conflict (e.g. by downgrading/pinning libs),
which can be fragile:

```bash
docker build --build-arg ROS_PACKAGE=ros-humble-desktop -t ... .
```

## Troubleshooting

- **Isaac Sim window doesn't render / black viewport over VNC.** Confirm
  `/dev/dri/renderD128` is present in the container (needs `--gpus all` +
  `NVIDIA_DRIVER_CAPABILITIES=all`) and that `run-isaacsim.sh` reports
  `launching via VirtualGL`. If VirtualGL truly can't help on your setup, the
  NVIDIA-recommended fallback is **WebRTC streaming** — run
  `isaacsim --no-window` and the WebRTC extension, or
  `/isaac-sim/runheadless.webrtc.sh --allow-root` on the official NVIDIA image,
  and connect with the Isaac Sim WebRTC Streaming Client (expose TCP 8211 +
  UDP 47995-48012, 49000-49007). VNC is best for the UI/tooling; WebRTC for
  heavy viewport work.
- **First launch is slow.** Isaac Sim compiles shaders and may download assets
  on first run. Mount a volume at `/root/.cache` and `/root/.nvidia-omniverse`
  to persist this across pod restarts.
- **"Kit cannot run as root".** Already handled — `OMNI_KIT_ALLOW_ROOT=1` is
  set in the image and `run-isaacsim.sh`'s environment.
- **Can't log in to the web UI.** Confirm `VNC_PW` is set; the entrypoint log
  (pod logs) prints whether the KasmVNC password was set successfully and
  whether `vncserver` started.
- **`ros2` CLI errors with undefined symbols after running Isaac Sim.** That
  means something registered Isaac's bundled ROS 2 libs globally. Don't add
  Isaac's lib paths to `ldconfig` or a global `LD_LIBRARY_PATH` — keep them
  scoped to the Isaac Sim process as `run-isaacsim.sh` does.
</content>
