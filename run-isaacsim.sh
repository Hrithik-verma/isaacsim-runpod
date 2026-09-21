#!/usr/bin/env bash
# Launch Isaac Sim (pip/conda) GUI.
# - Rendering goes through VirtualGL so GPU (Vulkan/RTX) frames are blitted into
#   the VNC framebuffer (without vglrun the Kit window is blank over KasmVNC).
# - The ROS 2 bridge needs Isaac's OWN bundled ROS 2 Humble libs on the
#   library path (system ROS 2 has an ABI mismatch with the prebuilt bridge).
#   We add them via a SCOPED LD_LIBRARY_PATH here -- NOT global ldconfig, which
#   would break the system `ros2` CLI. $EXT/bin holds the bridge .so itself.
set -e

ISAAC_ENV="${ISAAC_ENV:-env_isaacsim}"
source /opt/conda/etc/profile.d/conda.sh
conda activate "${ISAAC_ENV}"

export ROS_DISTRO=humble
export RMW_IMPLEMENTATION=rmw_fastrtps_cpp
export OMNI_KIT_ALLOW_ROOT=1
export ACCEPT_EULA=Y PRIVACY_CONSENT=Y OMNI_KIT_ACCEPT_EULA=YES
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/runtime-root}"
mkdir -p "${XDG_RUNTIME_DIR}" && chmod 700 "${XDG_RUNTIME_DIR}"

# ROS 2 bridge library path (scoped to this process). Globbed to survive version
# bumps (python3.11 vs 3.12, omni.usd.libs hash).
SITE="$(python -c 'import isaacsim, os; print(os.path.dirname(isaacsim.__file__))' 2>/dev/null || true)"
if [ -n "${SITE}" ]; then
    # Glob every isaacsim.ros2.* extension rather than naming one: the layout
    # moved in 6.x. Up to 5.x the bridge .so and the bundled distro libs lived
    # in isaacsim.ros2.bridge/{bin,humble/lib}; from 6.0 the bridge is a
    # meta-extension with no libraries, and they are spread over
    # isaacsim.ros2.{core,nodes,control,tf_viewer}/bin plus
    # isaacsim.ros2.core/humble/lib. Pointing at the old path makes
    # isaacsim.ros2.core log "ROS2 Bridge startup failed".
    ROS2_LIBS=""
    for d in "${SITE}"/exts/isaacsim.ros2.*/bin "${SITE}"/exts/isaacsim.ros2.*/"${ROS_DISTRO}"/lib; do
        [ -d "${d}" ] && ROS2_LIBS="${ROS2_LIBS:+${ROS2_LIBS}:}${d}"
    done
    USD_LIBS="$(ls -d "${SITE}"/extscache/omni.usd.libs-*/bin 2>/dev/null | head -1)"
    export LD_LIBRARY_PATH="${ROS2_LIBS}:${USD_LIBS}:${CONDA_PREFIX}/lib:${LD_LIBRARY_PATH:-}"
fi

echo "[run-isaacsim] env=${ISAAC_ENV}"

if command -v vglrun >/dev/null 2>&1 && [ -e /dev/dri/renderD128 ]; then
    echo "[run-isaacsim] launching via VirtualGL: vglrun -d egl0 isaacsim"
    exec vglrun -d egl0 isaacsim "$@"
else
    echo "[run-isaacsim] VirtualGL/GPU render node unavailable; launching isaacsim directly (may render blank over VNC)"
    exec isaacsim "$@"
fi
