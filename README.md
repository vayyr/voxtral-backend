# Voxtral Mini 4B Realtime - Local Backend

Real-time speech transcription backend using [Voxtral Mini 4B Realtime 2602](https://huggingface.co/mistralai/Voxtral-Mini-4B-Realtime-2602) served via vLLM with INT4 quantization.

## Quick Start

```bash
# 1. Install everything
bash setup.sh

# 2. Activate the environment
source .venv/bin/activate

# 3. Start the server (first run downloads the model ~9GB)
bash serve.sh

# 4. In another terminal, test with an audio file
source .venv/bin/activate
python test_file_transcribe.py --audio_path /path/to/audio.wav

# 5. Or stream from your microphone
python stream_microphone.py
```

## Server Details

- **Endpoint**: `ws://<your-ip>:8000/v1/realtime`
- **Model**: Voxtral Mini 4B Realtime 2602 (INT4 quantized via BitsAndBytes)
- **GPU**: Runs on RTX 3060 12GB with plenty of headroom
- **Max session**: ~44 minutes of continuous audio (configurable via `--max-model-len`)

## WebSocket API Protocol (for Flutter Integration)

The server exposes a WebSocket endpoint at `/v1/realtime`. Here's the message flow:

### Connection Flow

```
Client                          Server
  |                               |
  |--- connect ws://host:8000 --->|
  |<-- session.created -----------|
  |--- session.update ----------->|  (set model name)
  |--- input_audio_buffer.commit->|  (signal ready)
  |                               |
  |--- input_audio_buffer.append->|  (audio chunk 1)
  |--- input_audio_buffer.append->|  (audio chunk 2)
  |<-- transcription.delta -------|  (partial text)
  |--- input_audio_buffer.append->|  (audio chunk 3)
  |<-- transcription.delta -------|  (more text)
  |      ...                      |
  |--- input_audio_buffer.commit->|  (final=true, end session)
  |<-- transcription.done --------|  (final text + usage)
```

### Audio Format

| Property    | Value                |
|-------------|----------------------|
| Encoding    | PCM16 (signed 16-bit)|
| Sample rate | 16,000 Hz            |
| Channels    | 1 (mono)             |
| Transport   | Base64 encoded       |
| Chunk size  | ~3200 bytes (100ms)  |

### Message Types

#### Client → Server

**`session.update`** — Set the model:
```json
{"type": "session.update", "model": "mistralai/Voxtral-Mini-4B-Realtime-2602"}
```

**`input_audio_buffer.append`** — Send an audio chunk:
```json
{"type": "input_audio_buffer.append", "audio": "<base64-encoded-pcm16>"}
```

**`input_audio_buffer.commit`** — Signal ready or end of stream:
```json
{"type": "input_audio_buffer.commit"}
{"type": "input_audio_buffer.commit", "final": true}
```

#### Server → Client

**`session.created`** — Connection established:
```json
{"type": "session.created", "id": "session-uuid"}
```

**`transcription.delta`** — Partial transcription:
```json
{"type": "transcription.delta", "delta": "Hello "}
```

**`transcription.done`** — Final transcription:
```json
{"type": "transcription.done", "text": "Hello world", "usage": {...}}
```

### Flutter Client Example (Dart pseudocode)

```dart
import 'dart:convert';
import 'dart:typed_data';
import 'package:web_socket_channel/web_socket_channel.dart';

final channel = WebSocketChannel.connect(
  Uri.parse('ws://192.168.1.100:8000/v1/realtime'),
);

// Listen for transcription
channel.stream.listen((message) {
  final data = jsonDecode(message);
  if (data['type'] == 'session.created') {
    // Send model info
    channel.sink.add(jsonEncode({
      'type': 'session.update',
      'model': 'mistralai/Voxtral-Mini-4B-Realtime-2602',
    }));
    // Signal ready
    channel.sink.add(jsonEncode({'type': 'input_audio_buffer.commit'}));
  } else if (data['type'] == 'transcription.delta') {
    print('Partial: ${data["delta"]}');
  } else if (data['type'] == 'transcription.done') {
    print('Final: ${data["text"]}');
  }
});

// Send audio chunks from microphone
void sendAudioChunk(Uint8List pcm16Bytes) {
  channel.sink.add(jsonEncode({
    'type': 'input_audio_buffer.append',
    'audio': base64Encode(pcm16Bytes),
  }));
}
```

## Configuration

| Flag | Default | Description |
|------|---------|-------------|
| `--max-model-len` | 32768 | Max tokens (~44 min audio). Increase for longer sessions |
| `--gpu-memory-utilization` | 0.90 | Fraction of GPU memory to use |
| `--port` | 8000 | Server port |
| `--host` | 0.0.0.0 | Bind address (0.0.0.0 for LAN) |

### Transcription Delay

The model supports configurable transcription delays (80ms–2400ms). Default is **480ms** (best balance of quality and latency). To change, edit `transcription_delay_ms` in the model's `tekken.json` file.
