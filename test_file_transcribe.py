"""
Test client: transcribe an audio file via the vLLM Realtime WebSocket API.

Usage:
    python test_file_transcribe.py [--audio_path /path/to/audio.wav]
    python test_file_transcribe.py  # uses a built-in test tone

If no audio file is given, a short test tone is generated to verify the pipeline.
"""

import argparse
import asyncio
import base64
import json
import sys

import numpy as np

try:
    import websockets
except ImportError:
    print("Missing dependency: pip install websockets")
    sys.exit(1)


def generate_test_tone(duration_s: float = 3.0, sr: int = 16000) -> np.ndarray:
    """Generate a simple sine-wave test tone."""
    t = np.linspace(0, duration_s, int(sr * duration_s), endpoint=False)
    tone = (np.sin(2 * np.pi * 440 * t) * 0.5 * 32767).astype(np.int16)
    return tone


def load_audio_file(path: str, sr: int = 16000) -> np.ndarray:
    """Load an audio file and convert to PCM16 @ 16kHz mono."""
    import librosa
    audio, _ = librosa.load(path, sr=sr, mono=True)
    return (audio * 32767).astype(np.int16)


async def transcribe_audio(audio_pcm16: np.ndarray, host: str, port: int, model: str):
    """Stream audio to the vLLM Realtime API and print transcription."""
    uri = f"ws://{host}:{port}/v1/realtime"

    print(f"Connecting to {uri}...")
    async with websockets.connect(uri) as ws:
        # Wait for session.created
        response = json.loads(await ws.recv())
        if response["type"] == "session.created":
            print(f"Session created: {response['id']}")
        else:
            print(f"Unexpected response: {response}")
            return

        # Validate model
        await ws.send(json.dumps({"type": "session.update", "model": model}))

        # Signal ready to start
        await ws.send(json.dumps({"type": "input_audio_buffer.commit"}))

        # Send audio in chunks (4KB raw = ~128ms of audio at 16kHz mono 16-bit)
        audio_bytes = audio_pcm16.tobytes()
        chunk_size = 4096
        total_chunks = (len(audio_bytes) + chunk_size - 1) // chunk_size

        print(f"Sending {total_chunks} audio chunks ({len(audio_bytes)} bytes)...")
        for i in range(0, len(audio_bytes), chunk_size):
            chunk = audio_bytes[i : i + chunk_size]
            await ws.send(
                json.dumps({
                    "type": "input_audio_buffer.append",
                    "audio": base64.b64encode(chunk).decode("utf-8"),
                })
            )

        # Signal all audio is sent
        await ws.send(json.dumps({"type": "input_audio_buffer.commit", "final": True}))
        print("Audio sent. Waiting for transcription...\n")

        # Receive transcription
        print("Transcription: ", end="", flush=True)
        while True:
            response = json.loads(await ws.recv())
            if response["type"] == "transcription.delta":
                print(response["delta"], end="", flush=True)
            elif response["type"] == "transcription.done":
                print(f"\n\nFinal: {response['text']}")
                if response.get("usage"):
                    print(f"Usage: {response['usage']}")
                break
            elif response["type"] == "error":
                print(f"\nError: {response['error']}")
                break


def main():
    parser = argparse.ArgumentParser(description="Voxtral Realtime - Audio File Transcription Test")
    parser.add_argument("--audio_path", type=str, default=None, help="Path to audio file (wav, mp3, flac, etc.)")
    parser.add_argument("--host", type=str, default="localhost", help="Server host (default: localhost)")
    parser.add_argument("--port", type=int, default=8000, help="Server port (default: 8000)")
    parser.add_argument("--model", type=str, default="mistralai/Voxtral-Mini-4B-Realtime-2602")
    args = parser.parse_args()

    if args.audio_path:
        print(f"Loading audio from: {args.audio_path}")
        audio = load_audio_file(args.audio_path)
    else:
        print("No audio file provided — generating a 3s test tone (440Hz)")
        audio = generate_test_tone()

    asyncio.run(transcribe_audio(audio, args.host, args.port, args.model))


if __name__ == "__main__":
    main()
