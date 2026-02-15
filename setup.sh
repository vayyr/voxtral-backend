#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="$SCRIPT_DIR/.venv"

echo "=== Voxtral Mini 4B Realtime - Backend Setup ==="
echo ""

# 1. Install uv if not present
if ! command -v uv &>/dev/null; then
    echo ">>> Installing uv package manager..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
else
    echo ">>> uv already installed: $(uv --version)"
fi

# 2. Create virtual environment
if [ ! -d "$VENV_DIR" ]; then
    echo ">>> Creating Python virtual environment at $VENV_DIR..."
    uv venv "$VENV_DIR" --python 3.11
else
    echo ">>> Virtual environment already exists at $VENV_DIR"
fi

# Activate venv
source "$VENV_DIR/bin/activate"

# 3. Install vLLM nightly with CUDA auto-detection
echo ">>> Installing vLLM (nightly)..."
UV_HTTP_TIMEOUT=600 uv pip install -U vllm \
    --prerelease=allow \
    --index-strategy unsafe-best-match \
    --torch-backend=auto \
    --extra-index-url https://wheels.vllm.ai/nightly

# 4. Install BitsAndBytes + audio processing dependencies
echo ">>> Installing bitsandbytes and audio libraries..."
UV_HTTP_TIMEOUT=600 uv pip install -U bitsandbytes soxr librosa soundfile sounddevice websockets numpy

# 5. System dependency for sounddevice (microphone capture)
echo ">>> Checking for libportaudio2..."
if ! ldconfig -p | grep -q libportaudio; then
    echo "    Installing libportaudio2 (requires sudo)..."
    sudo apt-get install -y libportaudio2
else
    echo "    libportaudio2 already installed"
fi

# 6. Verify installations
echo ""
echo "=== Verification ==="
python -c "import vllm; print(f'vLLM version: {vllm.__version__}')"
python -c "import mistral_common; print(f'mistral_common version: {mistral_common.__version__}')"
python -c "import bitsandbytes; print(f'bitsandbytes version: {bitsandbytes.__version__}')"
python -c "import torch; print(f'torch version: {torch.__version__}'); print(f'CUDA available: {torch.cuda.is_available()}')"
python -c "import librosa; print(f'librosa version: {librosa.__version__}')"
python -c "import websockets; print(f'websockets version: {websockets.__version__}')"
python -c "import sounddevice; print(f'sounddevice version: {sounddevice.__version__}')"

echo ""
echo "=== Setup complete! ==="
echo "To activate the environment: source $VENV_DIR/bin/activate"
echo "To start the server: bash serve.sh"
