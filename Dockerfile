# RunPod template: Isaac Sim (pip/conda) GUI over KasmVNC (web) + ROS 2 Humble
#
# Isaac Sim is installed via pip INTO A CONDA ENV (env_isaacsim, Python 3.12)
# instead of the baked-in NVIDIA container, so you can swap versions later with
# a simple `pip install isaacsim[all,extscache]==<ver>` inside the env.
#
#   Build: ./build.sh -v 6.1.0.0        (or: docker build -t <you>/isaacsim-kasmvnc:6.1 .)
#   Run:   docker run --gpus all -e NVIDIA_DRIVER_CAPABILITIES=all \
#              -p 6901:6901 -e VNC_PW=secret <img>
#   Web:   http://<host>:6901   (RunPod: expose 6901 HTTP, 22 TCP)
FROM ubuntu:22.04

ARG KASMVNC_VERSION=1.4.0
# ---- Isaac Sim version knobs ------------------------------------------------
# Prefer ./build.sh -- it derives PYTHON_VERSION and TORCH_SPEC from the Isaac
# Sim version for you, and refuses versions NVIDIA does not publish:
#   ./build.sh -v 6.1.0.0            # or --list to see what is available
#
# Building by hand means keeping these three in sync. Isaac Sim wheels target
# exactly one CPython ABI, so the Python version is not a free choice:
#   6.x -> python 3.12    5.x -> python 3.11    4.x -> python 3.10
ARG ISAACSIM_PIP_VERSION=6.1.0.0
ARG PYTHON_VERSION=3.12
# TORCH_SPEC empty = don't install torch (the GUI alone doesn't need it; the
# RL / replicator extras do). Installed from TORCH_CUDA_INDEX before Isaac Sim.
ARG TORCH_SPEC=torch==2.11.0
ARG TORCH_CUDA_INDEX=https://download.pytorch.org/whl/cu128
ARG ROS_PACKAGE=ros-humble-ros-base
ARG DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-c"]

# Omniverse EULA + GPU capabilities (graphics needed for Vulkan rendering)
ENV ACCEPT_EULA=Y \
    PRIVACY_CONSENT=Y \
    OMNI_KIT_ACCEPT_EULA=YES \
    OMNI_KIT_ALLOW_ROOT=1 \
    LANG=en_US.UTF-8 \
    DISPLAY=:1 \
    NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=all

# ---------------------------------------------------------------------------
# 1. Desktop + tools + Isaac Sim runtime/X/Vulkan libraries
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        xfce4 xfce4-terminal terminator xterm dbus-x11 \
        openssh-server \
        sudo curl wget ca-certificates gnupg2 nano vim git less \
        net-tools iputils-ping software-properties-common locales tzdata \
        libvulkan1 vulkan-tools libgl1 libglu1-mesa libegl1 libglib2.0-0 \
        libsm6 libxext6 libxrender1 libxi6 libxrandr2 libxcursor1 \
        libxinerama1 libxkbcommon0 libxcomposite1 libxdamage1 libxtst6 \
        libnss3 libasound2 libxcb-xinerama0 libxcb-cursor0 libgomp1 \
    && apt-get purge -y xfce4-power-manager light-locker xfce4-screensaver 2>/dev/null || true \
    && locale-gen en_US.UTF-8 \
    && rm -rf /var/lib/apt/lists/*

# NVIDIA Vulkan + EGL ICDs (point at the driver libs injected at runtime by
# --gpus all + NVIDIA_DRIVER_CAPABILITIES=all). Belt-and-suspenders in case the
# container runtime doesn't drop these in.
RUN mkdir -p /etc/vulkan/icd.d /usr/share/glvnd/egl_vendor.d && \
    printf '{\n  "file_format_version": "1.0.0",\n  "ICD": {\n    "library_path": "libGLX_nvidia.so.0",\n    "api_version": "1.3"\n  }\n}\n' \
        > /etc/vulkan/icd.d/nvidia_icd.json && \
    printf '{\n  "file_format_version": "1.0.0",\n  "ICD": {\n    "library_path": "libEGL_nvidia.so.0"\n  }\n}\n' \
        > /usr/share/glvnd/egl_vendor.d/10_nvidia.json

# ---------------------------------------------------------------------------
# 2. KasmVNC (web VNC server)
# ---------------------------------------------------------------------------
RUN cd /tmp \
    && wget -q "https://github.com/kasmtech/KasmVNC/releases/download/v${KASMVNC_VERSION}/kasmvncserver_jammy_${KASMVNC_VERSION}_amd64.deb" \
    && apt-get update \
    && apt-get install -y --no-install-recommends ./kasmvncserver_jammy_${KASMVNC_VERSION}_amd64.deb \
    && rm -f /tmp/kasmvncserver_*.deb && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# 3. ROS 2 Humble (system install; sourced for the Isaac Sim ros2 bridge)
# ---------------------------------------------------------------------------
RUN add-apt-repository universe -y \
    && apt-get update \
    && ROS_APT_SOURCE_VERSION=$(curl -s https://api.github.com/repos/ros-infrastructure/ros-apt-source/releases/latest | grep -F '"tag_name"' | awk -F'"' '{print $4}') \
    && curl -L -o /tmp/ros2-apt-source.deb \
        "https://github.com/ros-infrastructure/ros-apt-source/releases/download/${ROS_APT_SOURCE_VERSION}/ros2-apt-source_${ROS_APT_SOURCE_VERSION}.jammy_all.deb" \
    && apt-get install -y /tmp/ros2-apt-source.deb \
    && apt-get update \
    && apt-get install -y --no-install-recommends ${ROS_PACKAGE} ros-dev-tools \
    && rm -f /tmp/ros2-apt-source.deb && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# 3b. VirtualGL (GPU-render 3D apps into the VNC framebuffer) + VS Code
# ---------------------------------------------------------------------------
RUN VGL_URL=$(curl -s https://api.github.com/repos/VirtualGL/virtualgl/releases/latest | grep -oE 'https://[^"]*virtualgl_[0-9.]+_amd64\.deb' | head -1) \
    && curl -L -o /tmp/vgl.deb "${VGL_URL}" \
    && apt-get update \
    && apt-get install -y --no-install-recommends /tmp/vgl.deb \
    && rm -f /tmp/vgl.deb \
    # VS Code (Microsoft apt repo)
    && curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --batch --yes --dearmor -o /usr/share/keyrings/microsoft.gpg \
    && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/code stable main" > /etc/apt/sources.list.d/vscode.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends code \
    # Google Chrome
    && curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | gpg --batch --yes --dearmor -o /usr/share/keyrings/google-chrome.gpg \
    && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google-chrome.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends google-chrome-stable \
    && rm -rf /var/lib/apt/lists/* \
    # root needs --no-sandbox; shadow both binaries with wrappers earlier in PATH
    # so `chrome`/`code` and the desktop icons just work as root.
    && printf '#!/bin/bash\nexec /usr/bin/google-chrome-stable --no-sandbox --user-data-dir=/root/.config/google-chrome "$@"\n' > /usr/local/bin/chrome \
    && printf '#!/bin/bash\nexec /usr/bin/code --no-sandbox --user-data-dir=/root/.vscode-root "$@"\n' > /usr/local/bin/code \
    && chmod +x /usr/local/bin/chrome /usr/local/bin/code

# ---------------------------------------------------------------------------
# 4. Miniforge + Isaac Sim (pip) in isolated envs  ->  version freedom
# Miniforge defaults to conda-forge (free, no Anaconda ToS/commercial license).
# ---------------------------------------------------------------------------
RUN wget -qO /tmp/miniforge.sh https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh \
    && bash /tmp/miniforge.sh -b -p /opt/conda \
    && rm /tmp/miniforge.sh \
    && /opt/conda/bin/conda create -y -n env_isaacsim python=${PYTHON_VERSION} \
    && /opt/conda/bin/conda clean -afy
ENV PATH=/opt/conda/bin:${PATH}

# PyTorch (CUDA) first, then Isaac Sim. To install a different Isaac Sim later:
#   conda activate env_isaacsim && pip install isaacsim[all,extscache]==<ver> --extra-index-url https://pypi.nvidia.com
RUN source /opt/conda/etc/profile.d/conda.sh && conda activate env_isaacsim \
    && if [ -n "${TORCH_SPEC}" ]; then pip install --no-cache-dir "${TORCH_SPEC}" --index-url "${TORCH_CUDA_INDEX}"; fi \
    && pip install --no-cache-dir "isaacsim[all,extscache]==${ISAACSIM_PIP_VERSION}" --extra-index-url https://pypi.nvidia.com

# NOTE: the isaacsim.ros2.bridge deps are made discoverable by a SCOPED
# LD_LIBRARY_PATH inside run-isaacsim.sh (Isaac process only). We deliberately
# do NOT register them via global ldconfig -- that pollutes the loader cache and
# breaks the system `ros2` CLI (rclpy picks up Isaac's spdlog/fmt -> undefined
# symbol in librcl_logging_spdlog.so).

# Make conda AVAILABLE but do NOT auto-activate any env (clean default shell).
# Activate manually when needed:  conda activate env_isaacsim
RUN /opt/conda/bin/conda config --set auto_activate_base false \
    && echo 'source /opt/conda/etc/profile.d/conda.sh' >> /root/.bashrc \
    && echo '# Isaac Sim lives in the env_isaacsim conda env: conda activate env_isaacsim' >> /root/.bashrc \
    && echo 'source /opt/ros/humble/setup.bash' >> /root/.bashrc

# ---------------------------------------------------------------------------
# 5. VNC / desktop config + launchers
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Make `isaacsim` work from a plain terminal, not just the launcher scripts.
#
# Isaac Sim 6.x native modules need GLIBCXX_3.4.32+; Ubuntu 22.04 ships
# libstdc++ 3.4.30 while the conda env has 3.4.36. Without conda's lib ahead of
# the system one, ~20 extensions fail to import ("cannot import name ... from
# (unknown location)"), the app never reaches "App is loaded", and Kit usually
# dies a few seconds later with no obvious cause.
#
# Scoped to the env via activate.d, so it applies on `conda activate
# env_isaacsim` and nowhere else. Only ${CONDA_PREFIX}/lib goes here -- Isaac's
# bundled ROS 2 libs stay scoped to run-isaacsim*.sh, because putting those on
# every shell's path breaks the system `ros2` CLI.
# PyNvVideoCodec: used only by nvenc-check.py, to prove an NVENC session can
# actually be OPENED. Loading the library is not a sufficient test -- rented
# GeForce hosts load it fine and still fail at session open.
RUN source /opt/conda/etc/profile.d/conda.sh && conda activate env_isaacsim \
    && pip install --no-cache-dir PyNvVideoCodec

RUN mkdir -p /opt/conda/envs/env_isaacsim/etc/conda/activate.d \
    && printf '%s\n' \
        '#!/bin/bash' \
        'export LD_LIBRARY_PATH="${CONDA_PREFIX}/lib:${LD_LIBRARY_PATH:-}"' \
        > /opt/conda/envs/env_isaacsim/etc/conda/activate.d/zz-isaacsim-libstdcxx.sh \
    && chmod +x /opt/conda/envs/env_isaacsim/etc/conda/activate.d/zz-isaacsim-libstdcxx.sh

# envsubst, for rendering the kasmvnc.yaml quality template in entrypoint.sh.
# Deliberately its OWN late layer: adding it to the apt layer near the top of
# this file invalidates the cache for the ~30GB Isaac Sim pip layer below it,
# turning a 40KB package into a 50-minute rebuild.
RUN apt-get update && apt-get install -y --no-install-recommends gettext-base \
    && rm -rf /var/lib/apt/lists/*

COPY vnc/xstartup /root/.vnc/xstartup
COPY vnc/kasmvnc.yaml /root/.vnc/kasmvnc.yaml.tmpl
COPY nvenc-check.py /usr/local/bin/nvenc-check.py
COPY run-isaacsim.sh /usr/local/bin/run-isaacsim.sh
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY vnc/IsaacSim.desktop /root/Desktop/IsaacSim.desktop
COPY vnc/GoogleChrome.desktop /root/Desktop/GoogleChrome.desktop
COPY vnc/VSCode.desktop /root/Desktop/VSCode.desktop
COPY vnc/xfwm4.xml /root/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml

RUN chmod +x /root/.vnc/xstartup /usr/local/bin/run-isaacsim.sh \
             /usr/local/bin/entrypoint.sh /root/Desktop/IsaacSim.desktop \
             /root/Desktop/GoogleChrome.desktop /root/Desktop/VSCode.desktop \
    # Pre-mark the DE so KasmVNC's select-de.sh doesn't prompt interactively.
    && touch /root/.vnc/.de-was-selected

EXPOSE 6901 22
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
