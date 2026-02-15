"""
Live microphone streaming client for Voxtral Realtime.

Captures audio from the default microphone and streams it via WebSocket
to the vLLM Realtime API for real-time transcription.

This demonstrates the same protocol a Flutter (or any other) client would use.

Usage:
    python stream_microphone.py [--host localhost] [--port 8000]

Requirements:
    pip install sounddevice websockets numpy
"""

import argparse
import asyncio
import base64
import json
import sys
import signal

import numpy as np

try:
    import sounddevice as sd
except ImportError:
    print("Missing dependency: pip install sounddevice")
    sys.exit(1)

try:
    import websockets
except ImportError:
    print("Missing dependency: pip install websockets")
    sys.exit(1)


SAMPLE_RATE = 16000      # 16kHz as required by Voxtral
CHANNELS = 1             # Mono
BLOCK_SIZE = 1600        # 100ms chunks at 16kHz (1600 samples * 2 bytes = 3200 bytes)
DTYPE = np.int16


async def stream_microphone(host: str, port: int, model: str):
    """Capture mic audio and stream to vLLM Realtime API."""
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

        # Signal ready
        await ws.send(json.dumps({"type": "input_audio_buffer.commit"}))

        # Audio queue for passing data from sounddevice callback to async sender
        audio_queue = asyncio.Queue()
        stop_event = asyncio.Event()

        def audio_callback(indata, frames, time_info, status):
            """Called by sounddevice for each audio block."""
            if status:
                print(f"Audio status: {status}", file=sys.stderr)
            # Convert to int16 and put in queue
            pcm16 = (indata[:, 0] * 32767).astype(np.int16)
            audio_queue.put_nowait(pcm16.tobytes())

        async def send_audio():
            """Send audio chunks from queue to WebSocket."""
            while not stop_event.is_set():
                try:
                    chunk = await asyncio.wait_for(audio_queue.get(), timeout=0.5)
                    await ws.send(
                        json.dumps({
                            "type": "input_audio_buffer.append",
                            "audio": base64.b64encode(chunk).decode("utf-8"),
                        })
                    )
                except asyncio.TimeoutError:
                    continue

        async def receive_transcription():
            """Receive and print transcription deltas."""
            while not stop_event.is_set():
                try:
                    response = json.loads(await asyncio.wait_for(ws.recv(), timeout=1.0))
                    if response["type"] == "transcription.delta":
                        print(response["delta"], end="", flush=True)
                    elif response["type"] == "transcription.done":
                        print(f"\n[Done] {response.get('text', '')}")
                    elif response["type"] == "error":
                        print(f"\n[Error] {response['error']}")
                        stop_event.set()
                except asyncio.TimeoutError:
                    continue
                except websockets.exceptions.ConnectionClosed:
                    print("\n[Connection closed]")
                    stop_event.set()

        # Handle Ctrl+C
        def handle_sigint(sig, frame):
            print("\n\nStopping...")
            stop_event.set()

        signal.signal(signal.SIGINT, handle_sigint)

        # Start microphone capture
        print("\n🎤 Recording... Press Ctrl+C to stop.\n")
        print("Transcription:\n" + "-" * 40)

        with sd.InputStream(
            samplerate=SAMPLE_RATE,
            channels=CHANNELS,
            dtype="float32",
            blocksize=BLOCK_SIZE,
            callback=audio_callback,
        ):
            # Run send and receive concurrently
            send_task = asyncio.create_task(send_audio())
            recv_task = asyncio.create_task(receive_transcription())

            # Wait for stop signal
            await stop_event.wait()

            # Clean up
            send_task.cancel()
            recv_task.cancel()

            # Send final commit
            try:
                await ws.send(json.dumps({"type": "input_audio_buffer.commit", "final": True}))
                # Wait briefly for any final transcription
                await asyncio.sleep(2)
            except Exception:
                pass

        print("\n" + "-" * 40)
        print("Session ended.")


def main():
    parser = argparse.ArgumentParser(description="Voxtral Realtime - Live Microphone Streaming")
    parser.add_argument("--host", type=str, default="localhost", help="Server host (default: localhost)")
    parser.add_argument("--port", type=int, default=8000, help="Server port (default: 8000)")
    parser.add_argument("--model", type=str, default="mistralai/Voxtral-Mini-4B-Realtime-2602")
    args = parser.parse_args()

    # List available audio devices
    print("Available audio devices:")
    print(sd.query_devices())
    print()

    asyncio.run(stream_microphone(args.host, args.port, args.model))


if __name__ == "__main__":
    main()
