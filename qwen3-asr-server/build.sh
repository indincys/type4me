#!/bin/bash
# Build the qwen3-asr-server PyInstaller binary.
#
# MLX is compiled from source with MLX_METAL_JIT=ON so the resulting binary
# works on macOS 14+ (any Apple Silicon) regardless of which macOS version
# was used to build.  JIT mode embeds Metal kernel sources in libmlx.dylib
# and compiles them at runtime for the host's Metal version, avoiding the
# "metallib language version 4.0 not supported" crash on older systems.
#
# Usage:
#   bash qwen3-asr-server/build.sh          # full rebuild (venv + PyInstaller)
#   bash qwen3-asr-server/build.sh --quick  # skip venv setup, PyInstaller only

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && /bin/pwd -P)"
cd "$SCRIPT_DIR"

QUICK=0
for arg in "$@"; do
    case "$arg" in
        --quick) QUICK=1 ;;
    esac
done

PYTHON="${PYTHON:-python3.12}"
VENV_DIR=".venv"
MIN_MACOS="14.0"

# --- venv + dependencies ---------------------------------------------------
if [ "$QUICK" = "0" ]; then
    echo "=== [qwen3-asr-server] Setting up venv ==="
    if [ ! -d "$VENV_DIR" ]; then
        $PYTHON -m venv "$VENV_DIR"
    fi
    source "$VENV_DIR/bin/activate"

    echo "=== [qwen3-asr-server] Installing MLX (JIT mode, target macOS $MIN_MACOS) ==="
    # Install MLX from source with JIT mode for backward compatibility.
    # This compiles Metal kernels at runtime, adapting to the host's Metal
    # version instead of shipping a pre-compiled metallib tied to one OS.
    CMAKE_ARGS="-DMLX_METAL_JIT=ON -DCMAKE_OSX_DEPLOYMENT_TARGET=$MIN_MACOS" \
        pip install mlx --no-binary mlx

    echo "=== [qwen3-asr-server] Installing remaining dependencies ==="
    pip install -r requirements.txt
else
    source "$VENV_DIR/bin/activate"
fi

# --- PyInstaller build ------------------------------------------------------
echo "=== [qwen3-asr-server] Building with PyInstaller ==="
pip install pyinstaller 2>/dev/null

pyinstaller --clean --noconfirm qwen3-asr-server.spec

DIST="$SCRIPT_DIR/dist/qwen3-asr-server"
if [ -d "$DIST" ]; then
    # Report metallib size to verify JIT mode is active (should be ~2-5MB, not ~125MB)
    METALLIB=$(find "$DIST" -name "mlx.metallib" 2>/dev/null | head -1)
    if [ -n "$METALLIB" ]; then
        SIZE=$(du -h "$METALLIB" | cut -f1)
        echo "[qwen3-asr-server] mlx.metallib size: $SIZE (JIT mode: expect ~2-5MB, not ~125MB)"
    fi
    TOTAL=$(du -sh "$DIST" | cut -f1)
    echo "=== [qwen3-asr-server] Build complete ($TOTAL) ==="
else
    echo "ERROR: qwen3-asr-server PyInstaller dist not found"
    exit 1
fi
