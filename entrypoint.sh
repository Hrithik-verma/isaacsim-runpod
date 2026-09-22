#!/usr/bin/env bash
# Entrypoint: configure + launch KasmVNC with an XFCE desktop, then keep the
# container alive by tailing the VNC log. Runs on RunPod as PID 1.
set -euo pipefail

: "${VNC_USER:=kasm_user}"      # web login username
: "${VNC_PW:=isaacsim}"         # web login password (CHANGE THIS)
: "${RESOLUTION:=1920x1080}"    # desktop resolution
: "${VNC_PORT:=6901}"           # KasmVNC web/websocket port
: "${VNC_DISPLAY:=:1}"

# Image quality knobs substituted into ~/.vnc/kasmvnc.yaml below. Defaults
# favour a clean 3D viewport over bandwidth; see the comments in that file.
# These must be EXPORTED, not just set: envsubst reads the environment, so a
# plain `: "${VAR:=default}"` renders the template with empty values.
export KASM_MIN_QUALITY="${KASM_MIN_QUALITY:-8}"              # 0-9, rect quality floor (stock: 7)
export KASM_MAX_QUALITY="${KASM_MAX_QUALITY:-9}"              # 0-9, 9 = best (stock: 8); 10 is OUT OF RANGE
                                                              # and makes Xvnc refuse to start
export KASM_JPEG_QUALITY="${KASM_JPEG_QUALITY:-9}"            # video mode, -1 = auto (stock: -1)
export KASM_WEBP_QUALITY="${KASM_WEBP_QUALITY:-9}"            # video mode, -1 = auto (stock: -1)
export KASM_VIDEO_AREA_THRESHOLD="${KASM_VIDEO_AREA_THRESHOLD:-98%}"  # % screen change that trips video mode
export KASM_MAX_FRAME_RATE="${KASM_MAX_FRAME_RATE:-60}"

export HOME=/root
export DISPLAY="${VNC_DISPLAY}"

# ---------------------------------------------------------------------------
# Name the GPU render-node group (mounted in by --gpus) so shells don't warn
# "cannot find name for group ID N". GID is host-specific, so read it live.
# ---------------------------------------------------------------------------
if [ -e /dev/dri/renderD128 ]; then
    rgid="$(stat -c '%g' /dev/dri/renderD128)"
    if [ -n "${rgid}" ] && ! getent group "${rgid}" >/dev/null 2>&1; then
        groupadd -g "${rgid}" render >/dev/null 2>&1 || true
    fi
fi

# ---------------------------------------------------------------------------
# SSH (RunPod injects your account's public key via $PUBLIC_KEY)
# ---------------------------------------------------------------------------
mkdir -p /root/.ssh /run/sshd
chmod 700 /root/.ssh
if [ -n "${PUBLIC_KEY:-}" ]; then
    echo "${PUBLIC_KEY}" > /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    echo "[entrypoint] Installed SSH public key from \$PUBLIC_KEY."
else
    echo "[entrypoint] WARNING: \$PUBLIC_KEY not set — SSH key auth will fail."
fi
ssh-keygen -A >/dev/null 2>&1 || true
/usr/sbin/sshd
echo "[entrypoint] sshd listening on port 22."

echo "[entrypoint] Configuring KasmVNC user '${VNC_USER}' ..."
# kasmvncpasswd prompts for the password AND a "Verify:" line, so feed it twice.
# Wrapped in set +e so a hiccup here never crash-loops the whole container.
set +e
printf '%s\n%s\n' "${VNC_PW}" "${VNC_PW}" | kasmvncpasswd -u "${VNC_USER}" -wo /root/.kasmpasswd
pw_rc=$?
set -e
if [ "${pw_rc}" -ne 0 ] || [ ! -s /root/.kasmpasswd ]; then
    echo "[entrypoint] ERROR: could not set KasmVNC password (rc=${pw_rc}); web login will fail."
else
    echo "[entrypoint] KasmVNC password set for '${VNC_USER}'."
fi

# Render the kasmvnc.yaml template (KASM_* -> values). The image ships the
# template at /root/.vnc/kasmvnc.yaml.tmpl so a restart re-renders from the
# original rather than from an already-substituted file.
if [ -f /root/.vnc/kasmvnc.yaml.tmpl ]; then
    envsubst '${KASM_MIN_QUALITY} ${KASM_MAX_QUALITY} ${KASM_JPEG_QUALITY} ${KASM_WEBP_QUALITY} ${KASM_VIDEO_AREA_THRESHOLD} ${KASM_MAX_FRAME_RATE}' \
        < /root/.vnc/kasmvnc.yaml.tmpl > /root/.vnc/kasmvnc.yaml
    # Only the substituted scalars -- a bare 'network:' section header also ends
    # in a colon and must not trip this.
    if grep -qE '^[[:space:]]+(min_quality|max_quality|jpeg_quality|webp_quality|area_threshold|max_frame_rate):[[:space:]]*$' /root/.vnc/kasmvnc.yaml; then
        echo "[entrypoint] ERROR: kasmvnc.yaml has empty values after substitution;" >&2
        echo "[entrypoint] falling back to KasmVNC defaults rather than shipping invalid YAML." >&2
        rm -f /root/.vnc/kasmvnc.yaml
    fi
    echo "[entrypoint] KasmVNC quality: rect ${KASM_MIN_QUALITY}-${KASM_MAX_QUALITY}, video jpeg/webp ${KASM_JPEG_QUALITY}/${KASM_WEBP_QUALITY}, video mode above ${KASM_VIDEO_AREA_THRESHOLD} screen change."
fi

# Clean any stale lock from a previous run (important for RunPod restarts).
vncserver -kill "${VNC_DISPLAY}" >/dev/null 2>&1 || true
rm -f "/tmp/.X11-unix/X${VNC_DISPLAY#:}" "/tmp/.X${VNC_DISPLAY#:}-lock" 2>/dev/null || true

echo "[entrypoint] Starting KasmVNC on ${VNC_DISPLAY} (web port ${VNC_PORT}, ${RESOLUTION}) ..."
# ~/.vnc/xstartup exists and ~/.vnc/.de-was-selected is pre-created, so
# select-de.sh short-circuits (no interactive DE prompt) and uses our xstartup.
set +e
vncserver "${VNC_DISPLAY}" \
    -geometry "${RESOLUTION}" \
    -depth 24 \
    -websocketPort "${VNC_PORT}"
vnc_rc=$?
set -e
if [ "${vnc_rc}" -ne 0 ]; then
    echo "[entrypoint] ERROR: vncserver failed to start (rc=${vnc_rc}). Container"
    echo "[entrypoint] will stay up so you can inspect logs / exec in and debug."
fi

echo "[entrypoint] KasmVNC is up."
echo "[entrypoint]   Web UI : http://<host>:${VNC_PORT}/"
echo "[entrypoint]   Login  : ${VNC_USER} / (VNC_PW)"
echo "[entrypoint]   Launch Isaac Sim from the desktop icon, or run:"
echo "[entrypoint]     run-isaacsim.sh"

# Keep PID 1 alive and stream the session log.
LOG="$(ls -t /root/.vnc/*.log 2>/dev/null | head -n1 || true)"
exec tail -F "${LOG:-/dev/null}"
