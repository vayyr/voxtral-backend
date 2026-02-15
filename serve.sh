#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/.venv/bin/activate"

echo "=== Starting Voxtral Mini 4B Realtime Server (BF16) ==="
echo "Binding to 0.0.0.0:8000 for LAN access"
echo ""

# NOTE: BitsAndBytes quantization has a shape mismatch bug with VoxtralRealtime
# architecture in vLLM 0.16.x, so we run in BF16 with reduced max-model-len.
# --max-model-len 4096 = ~5.5 min of audio. Adjust if needed (each token = 80ms).
# --gpu-memory-utilization 0.95 = use almost all 12GB VRAM.

VLLM_DISABLE_COMPILE_CACHE=1 vllm serve mistralai/Voxtral-Mini-4B-Realtime-2602 \
    --host 0.0.0.0 \
    --port 8000 \
    --enforce-eager \
    --max-model-len 4096 \
    --gpu-memory-utilization 0.95
