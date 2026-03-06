#!/bin/bash
# AegisTecPlus Autonomous Dev Cycle
# Compile → Flash → Wait → Capture screen (multiple frames)
#
# Usage: ./dev_cycle.sh [wait_seconds]
#   wait_seconds: initial wait for controller boot (default: 8)
#
# Environment variables (override defaults):
#   SPLAT_EXE    - path to splat.exe compiler
#   MTP_EXE      - path to MtpCopy.exe
#   FFMPEG_EXE   - path to ffmpeg.exe
#   WEBCAM_NAME  - DirectShow webcam device name (default: "Brio 101")
#
# Captures 8 frames spaced 1s apart to catch error screens
# that display for ~5s before rebooting in a loop.

set -e

# Project directory (always where this script lives)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"

# Tool paths - use env vars or auto-detect
if [ -z "$SPLAT_EXE" ]; then
    # Try common install locations
    for p in \
        "C:/Claude/dash-application/resources/app/plugins/splat-controls.splat-vscode/dist/bin/splat.exe" \
        "$LOCALAPPDATA/Programs/dash-application/resources/app/plugins/splat-controls.splat-vscode/dist/bin/splat.exe" \
        "$APPDATA/../Local/Programs/dash-application/resources/app/plugins/splat-controls.splat-vscode/dist/bin/splat.exe" \
        "C:/Users/$USERNAME/AppData/Local/Programs/dash-application/resources/app/plugins/splat-controls.splat-vscode/dist/bin/splat.exe"
    do
        if [ -f "$p" ]; then
            SPLAT_EXE="$p"
            break
        fi
    done
fi

if [ -z "$MTP_EXE" ]; then
    MTP_EXE="$PROJECT_DIR/MtpCopy.exe"
fi

if [ -z "$NODE_EXE" ]; then
    # Prefer local bundled node, fall back to PATH
    LOCAL_NODE="$PROJECT_DIR/node/node-v22.14.0-win-x64/node.exe"
    if [ -f "$LOCAL_NODE" ]; then
        NODE_EXE="$LOCAL_NODE"
    elif command -v node >/dev/null 2>&1; then
        NODE_EXE="$(command -v node)"
    fi
fi

CAPTURE_DIR="$PROJECT_DIR/screen_captures"
WAIT_SECONDS="${1:-15}"
NUM_CAPTURES=8
CAPTURE_INTERVAL=1

# Validate tools
for tool_var in SPLAT_EXE MTP_EXE NODE_EXE; do
    eval tool_path=\$$tool_var
    if [ -z "$tool_path" ] || [ ! -f "$tool_path" ]; then
        echo "ERROR: $tool_var not found: $tool_path"
        echo "Set the $tool_var environment variable to the correct path."
        exit 99
    fi
done

# Create capture directory
mkdir -p "$CAPTURE_DIR"

echo "============================================"
echo "  AegisTecPlus Dev Cycle"
echo "============================================"
echo "  Compiler: $SPLAT_EXE"
echo "  Flasher:  $MTP_EXE"
echo "  Node:     $NODE_EXE"
echo ""

# Step 1: Compile (using splat_build.js which patches splat.exe to produce .b1n + .lst)
echo "[1/4] Compiling _build.b1d..."
cd "$PROJECT_DIR"
COMPILE_OUTPUT=$("$NODE_EXE" splat_build.js "_build.b1d" 2>&1) || true
echo "$COMPILE_OUTPUT"

if echo "$COMPILE_OUTPUT" | grep -q "BUILD SUCCESS"; then
    echo "  >> Compilation OK"
else
    echo "  >> COMPILATION FAILED - aborting"
    exit 1
fi
echo ""

# Step 2: Flash to device
echo "[2/4] Flashing to AV430..."
B1N_WIN=$(cygpath -w "$PROJECT_DIR/_build.b1n")
FLASH_OUTPUT=$("$MTP_EXE" "$B1N_WIN" 2>&1)
echo "$FLASH_OUTPUT"

if echo "$FLASH_OUTPUT" | grep -q "SUCCESS"; then
    echo "  >> Flash OK"
else
    echo "  >> FLASH FAILED - aborting"
    exit 2
fi
echo ""

# Step 3: Wait for boot
echo "[3/4] Waiting ${WAIT_SECONDS}s for controller boot..."
sleep "$WAIT_SECONDS"
echo "  >> Boot wait complete"
echo ""

# Step 4: Capture multiple frames via overhead Global Shutter camera
echo "[4/4] Capturing ${NUM_CAPTURES} frames (${CAPTURE_INTERVAL}s apart)..."
CAPTURE_DIR_WIN=$(cygpath -w "$CAPTURE_DIR")
powershell -ExecutionPolicy Bypass -File "$PROJECT_DIR/screen_capture.ps1" \
    -CaptureDir "$CAPTURE_DIR_WIN" -NumCaptures $NUM_CAPTURES -IntervalSec $CAPTURE_INTERVAL
echo "  >> Capture complete"
echo ""

echo "============================================"
echo "  Cycle complete. Captures in: $CAPTURE_DIR"
echo "============================================"
