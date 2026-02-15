#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/.venv/bin/activate"

echo "=== Voxtral Mini 4B Realtime Server (auto-restart) ==="
echo "Binding to 0.0.0.0:8000 for LAN access"
echo "Press Ctrl+C twice to fully stop."
echo ""

while true; do
    echo "[$(date)] Starting vLLM server..."
    
    VLLM_DISABLE_COMPILE_CACHE=1 vllm serve mistralai/Voxtral-Mini-4B-Realtime-2602 \
        --host 0.0.0.0 \
        --port 8000 \
        --enforce-eager \
        --max-model-len 4096 \
        --gpu-memory-utilization 0.95
    
    EXIT_CODE=$?
    echo ""
    echo "[$(date)] Server exited with code $EXIT_CODE"
    
    if [ $EXIT_CODE -eq 130 ] || [ $EXIT_CODE -eq 137 ]; then
        echo "Server stopped by user (SIGINT/SIGKILL). Exiting."
        break
    fi
    
    echo "Restarting in 3 seconds..."
    sleep 3
done
