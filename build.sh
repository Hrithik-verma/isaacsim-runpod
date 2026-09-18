#!/usr/bin/env bash
# Build an Isaac Sim image for ANY Isaac Sim pip release.
#
# Isaac Sim is installed with pip into a conda env, so the version is just a
# build argument. This script picks the Python version and the PyTorch wheel
# that the requested Isaac Sim release actually supports, so callers only ever
# have to say which Isaac Sim they want:
#
#   ./build.sh                      # default version (see ISAACSIM_DEFAULT)
#   ./build.sh -v 5.1.0.0           # any release on pypi.nvidia.com
#   ./build.sh -v 6.1.0.0 --push    # build and push to Docker Hub
#   ./build.sh --list               # what NVIDIA currently publishes
#   ./build.sh --clean -v 6.1.0.0   # reclaim docker disk first, then build
#
# The version->Python mapping is NOT advisory: Isaac Sim wheels are built for
# exactly one CPython ABI (Requires-Python: ==3.12.* for 6.x), so building 6.x
# on Python 3.11 fails at pip resolve time with a confusing "no matching
# distribution" error.
set -euo pipefail

ISAACSIM_DEFAULT=6.1.0.0
IMAGE_DEFAULT=hrithik108/ubuntu-isaac-sim

VERSION=$ISAACSIM_DEFAULT
IMAGE=$IMAGE_DEFAULT
TAG=
PUSH=0
CLEAN=0
LATEST=0
NO_TORCH=0
TORCH_SPEC_OVERRIDE=
EXTRA_ARGS=()

die() { echo "error: $*" >&2; exit 1; }

usage() {
    sed -n '2,/^set -euo/p' "$0" | sed 's/^# \?//;$d'
    cat <<'EOF'
Options:
  -v, --version VER    Isaac Sim pip version (e.g. 6.1.0.0, 5.1.0.0, 4.5.0.0)
  -i, --image NAME     image repository (default: see ISAACSIM_DEFAULT above)
  -t, --tag TAG        image tag (default: the Isaac Sim version)
      --latest         also tag :latest
      --push           docker push after a successful build
      --clean          prune docker build cache + dangling images before building
      --torch SPEC     override the PyTorch spec (e.g. torch==2.10.0)
      --no-torch       skip PyTorch entirely (smaller image; GUI-only use)
      --list           list Isaac Sim versions available on pypi.nvidia.com
  -h, --help           this message

Anything after `--` is passed straight to `docker build`.
EOF
}

list_versions() {
    curl -fsSL https://pypi.nvidia.com/isaacsim/ \
        | grep -oE 'isaacsim-[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+-cp[0-9]+' \
        | sed -E 's/isaacsim-(.*)-cp([0-9])([0-9]+)/\1  (python \2.\3)/' \
        | sort -uV
}

# Python ABI + PyTorch wheel per Isaac Sim release line.
# torch is optional for GUI-only use; the RL/replicator extras want it.
resolve_deps() {
    case "$1" in
        6.*) PYTHON_VERSION=3.12; TORCH_SPEC=torch==2.11.0 ;;
        5.*) PYTHON_VERSION=3.11; TORCH_SPEC=torch==2.7.0  ;;
        4.5*) PYTHON_VERSION=3.10; TORCH_SPEC=torch==2.5.1 ;;
        4.*) PYTHON_VERSION=3.10; TORCH_SPEC=torch==2.4.0  ;;
        *)   die "unknown Isaac Sim series '$1'; add it to resolve_deps() in $0" ;;
    esac
    TORCH_CUDA_INDEX=https://download.pytorch.org/whl/cu128
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -v|--version) VERSION=${2:?}; shift 2 ;;
        -i|--image)   IMAGE=${2:?};   shift 2 ;;
        -t|--tag)     TAG=${2:?};     shift 2 ;;
        --latest)     LATEST=1; shift ;;
        --push)       PUSH=1;   shift ;;
        --clean)      CLEAN=1;  shift ;;
        --torch)      TORCH_SPEC_OVERRIDE=${2:?}; shift 2 ;;
        --no-torch)   NO_TORCH=1; shift ;;
        --list)       list_versions; exit 0 ;;
        -h|--help)    usage; exit 0 ;;
        --)           shift; EXTRA_ARGS+=("$@"); break ;;
        *)            die "unknown option '$1' (try --help)" ;;
    esac
done

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] \
    || die "version '$VERSION' is not an Isaac Sim pip version (e.g. 6.1.0.0)"

resolve_deps "$VERSION"
[[ -n "$TORCH_SPEC_OVERRIDE" ]] && TORCH_SPEC=$TORCH_SPEC_OVERRIDE
[[ $NO_TORCH -eq 1 ]] && TORCH_SPEC=

# Tag from the version, dropping a trailing zero 4th component: 6.1.0.0 -> 6.1.0.
# Only a zero 4th component, and only when there is one: 6.0.0.1 and 4.2.0.2 are
# distinct releases that would collide with their .0 siblings if trimmed, and a
# 3-component version like 6.1.0 must not become 6.1.
if [[ -z "$TAG" ]]; then
    if [[ "$VERSION" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\.0$ ]]; then
        TAG=${BASH_REMATCH[1]}
    else
        TAG=$VERSION
    fi
fi

# Fail before a multi-hour build rather than after it.
if ! curl -fsSL https://pypi.nvidia.com/isaacsim/ | grep -q "isaacsim-${VERSION}-cp"; then
    echo "error: isaacsim ${VERSION} is not on pypi.nvidia.com. Available:" >&2
    list_versions >&2
    exit 1
fi

if [[ $CLEAN -eq 1 ]]; then
    echo "==> reclaiming docker disk (build cache + dangling images)"
    # Deliberately NOT `image prune -a`: that deletes every image not currently
    # attached to a container, including unrelated ones you still want.
    docker builder prune -af >/dev/null
    docker image prune -f  >/dev/null
    docker system df
fi

echo "==> Isaac Sim ${VERSION} | python ${PYTHON_VERSION} | torch ${TORCH_SPEC:-<none>}"
echo "==> building ${IMAGE}:${TAG}"

cd "$(dirname "$0")"
docker build \
    --build-arg "ISAACSIM_PIP_VERSION=${VERSION}" \
    --build-arg "PYTHON_VERSION=${PYTHON_VERSION}" \
    --build-arg "TORCH_SPEC=${TORCH_SPEC}" \
    --build-arg "TORCH_CUDA_INDEX=${TORCH_CUDA_INDEX}" \
    -t "${IMAGE}:${TAG}" \
    "${EXTRA_ARGS[@]}" \
    .

if [[ $LATEST -eq 1 ]]; then
    docker tag "${IMAGE}:${TAG}" "${IMAGE}:latest"
    echo "==> tagged ${IMAGE}:latest"
fi

if [[ $PUSH -eq 1 ]]; then
    echo "==> pushing ${IMAGE}:${TAG}"
    docker push "${IMAGE}:${TAG}"
    [[ $LATEST -eq 1 ]] && docker push "${IMAGE}:latest"
fi

echo "==> done: ${IMAGE}:${TAG}"
