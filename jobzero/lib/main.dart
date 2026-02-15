import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform, HttpClient, ContentType;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

// ─── Configuration ──────────────────────────────────────────────────────────
const String kServerHost = '100.111.74.127';
const int kServerPort = 8000;
const String kModel = 'mistralai/Voxtral-Mini-4B-Realtime-2602';
const int kSampleRate = 16000;

const String kLlmHost = '192.168.1.156';
const int kLlmPort = 1234;

// ─── Accent ─────────────────────────────────────────────────────────────────
const Color kAccent = Color(0xFFD4A574);
const Color kAiAccent = Color(0xFF7AA2D4); // cool blue for AI responses

// ─── Data Model ─────────────────────────────────────────────────────────────

class ChatMessage {
  final String query;
  String response;
  bool isStreaming;

  ChatMessage({
    required this.query,
    this.response = '',
    this.isStreaming = true,
  });
}

class TranscriptCard {
  final DateTime createdAt;
  String text;
  String partialText;
  final List<ChatMessage> chatMessages;

  TranscriptCard({
    required this.createdAt,
    this.text = '',
    this.partialText = '',
  }) : chatMessages = [];

  String get timestamp {
    final h = createdAt.hour.toString().padLeft(2, '0');
    final m = createdAt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  bool get isEmpty => text.isEmpty && partialText.isEmpty;
  bool get hasContent => text.isNotEmpty || partialText.isNotEmpty;
}

// ─── App ────────────────────────────────────────────────────────────────────

void main() => runApp(const JobZeroApp());

class JobZeroApp extends StatelessWidget {
  const JobZeroApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'JobZero',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.black,
        fontFamily: 'SF Pro Display',
        colorScheme: const ColorScheme.dark(
          primary: Colors.white,
          surface: Colors.black,
        ),
      ),
      home: const TranscriptionScreen(),
    );
  }
}

// ─── Main Screen ────────────────────────────────────────────────────────────

class TranscriptionScreen extends StatefulWidget {
  const TranscriptionScreen({super.key});

  @override
  State<TranscriptionScreen> createState() => _TranscriptionScreenState();
}

class _TranscriptionScreenState extends State<TranscriptionScreen>
    with TickerProviderStateMixin {
  // State
  bool _isRecording = false;
  bool _isConnected = false;
  bool _isConnecting = false;
  String? _errorMessage;

  // Cards
  final List<TranscriptCard> _cards = [];
  int _activeCardIndex = -1;
  int? _chatCardIndex; // card currently being chatted with
  final TextEditingController _chatController = TextEditingController();
  final FocusNode _chatFocus = FocusNode();

  // Audio & WebSocket
  final AudioRecorder _recorder = AudioRecorder();
  WebSocketChannel? _channel;
  StreamSubscription? _audioSubscription;
  StreamSubscription? _wsSubscription;
  final ScrollController _scrollController = ScrollController();

  // Animations
  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
  }

  @override
  void dispose() {
    _stopSession();
    _recorder.dispose();
    _pulseController.dispose();
    _scrollController.dispose();
    _chatController.dispose();
    _chatFocus.dispose();
    super.dispose();
  }

  // ─── Card management ──────────────────────────────────────────────────

  void _createNewCard() {
    setState(() {
      _cards.add(TranscriptCard(createdAt: DateTime.now()));
      _activeCardIndex = _cards.length - 1;
    });
    _scrollToBottom();
  }

  TranscriptCard? get _activeCard =>
      _activeCardIndex >= 0 && _activeCardIndex < _cards.length
      ? _cards[_activeCardIndex]
      : null;

  void _scrollToCard(int index) {
    final targetOffset = index * 180.0;
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        targetOffset.clamp(0, _scrollController.position.maxScrollExtent),
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _openChatForCard(int index) {
    setState(() {
      _chatCardIndex = _chatCardIndex == index ? null : index;
    });
    if (_chatCardIndex != null) {
      Future.delayed(const Duration(milliseconds: 100), () {
        _chatFocus.requestFocus();
      });
    }
  }

  // ─── LLM Chat ─────────────────────────────────────────────────────────

  Future<void> _sendChatMessage(int cardIndex) async {
    final query = _chatController.text.trim();
    if (query.isEmpty) return;

    final card = _cards[cardIndex];
    final chatMsg = ChatMessage(query: query);

    setState(() {
      card.chatMessages.add(chatMsg);
      _chatController.clear();
    });
    _scrollToBottom();

    try {
      final client = HttpClient();
      final uri = Uri.parse('http://$kLlmHost:$kLlmPort/v1/chat/completions');
      final request = await client.postUrl(uri);
      request.headers.contentType = ContentType.json;

      final body = jsonEncode({
        'messages': [
          {
            'role': 'system',
            'content':
                'You are a helpful assistant analyzing a live meeting transcription. Be concise and direct.',
          },
          {
            'role': 'user',
            'content':
                'Here is the transcription so far:\n\n'
                '${card.text}${card.partialText.isNotEmpty ? '\n${card.partialText}' : ''}\n\n'
                'Question: $query',
          },
        ],
        'stream': true,
        'temperature': 0.7,
        'max_tokens': 1024,
      });

      request.write(body);
      final response = await request.close();

      // Parse SSE stream
      String buffer = '';
      await for (final chunk in response.transform(utf8.decoder)) {
        buffer += chunk;
        final lines = buffer.split('\n');
        buffer = lines.removeLast(); // keep incomplete line

        for (final line in lines) {
          if (line.startsWith('data: ')) {
            final data = line.substring(6).trim();
            if (data == '[DONE]') {
              setState(() => chatMsg.isStreaming = false);
              break;
            }
            try {
              final json = jsonDecode(data) as Map<String, dynamic>;
              final choices = json['choices'] as List?;
              if (choices != null && choices.isNotEmpty) {
                final delta = choices[0]['delta'] as Map<String, dynamic>?;
                final content = delta?['content'] as String?;
                if (content != null) {
                  setState(() => chatMsg.response += content);
                  _scrollToBottom();
                }
              }
            } catch (_) {}
          }
        }
      }

      setState(() => chatMsg.isStreaming = false);
      client.close();
    } catch (e) {
      debugPrint('LLM error: $e');
      setState(() {
        chatMsg.response = 'Error: $e';
        chatMsg.isStreaming = false;
      });
    }
  }

  // ─── Session lifecycle ──────────────────────────────────────────────────

  Future<void> _startSession() async {
    if (!kIsWeb && Platform.isMacOS) {
      final hasPerm = await _recorder.hasPermission();
      if (!hasPerm) {
        setState(() => _errorMessage = 'Microphone permission denied');
        return;
      }
    } else {
      final status = await Permission.microphone.request();
      if (!status.isGranted) {
        setState(() => _errorMessage = 'Microphone permission denied');
        return;
      }
    }

    setState(() {
      _isConnecting = true;
      _errorMessage = null;
    });

    try {
      final uri = Uri.parse('ws://$kServerHost:$kServerPort/v1/realtime');
      _channel = WebSocketChannel.connect(uri);
      await _channel!.ready;

      _wsSubscription = _channel!.stream.listen(
        _onServerMessage,
        onError: (error) {
          _setError('Connection error');
          _stopSession();
        },
        onDone: () {
          if (_isRecording) {
            _setError('Connection closed');
            _stopSession();
          }
        },
      );
    } catch (e) {
      _setError('Could not connect');
      setState(() => _isConnecting = false);
    }
  }

  void _onServerMessage(dynamic message) {
    final data = jsonDecode(message as String) as Map<String, dynamic>;
    final type = data['type'] as String;

    switch (type) {
      case 'session.created':
        _onSessionCreated(data);
        break;
      case 'transcription.delta':
        _onTranscriptionDelta(data);
        break;
      case 'transcription.done':
        _onTranscriptionDone(data);
        break;
      case 'error':
        _setError(data['error']?.toString() ?? 'Unknown error');
        break;
    }
  }

  Future<void> _onSessionCreated(Map<String, dynamic> data) async {
    debugPrint('Session created: ${data['id']}');

    _channel!.sink.add(jsonEncode({'type': 'session.update', 'model': kModel}));
    _channel!.sink.add(jsonEncode({'type': 'input_audio_buffer.commit'}));

    if (_cards.isEmpty || _activeCard == null || !_activeCard!.isEmpty) {
      _createNewCard();
    }

    await _startMicStream();

    setState(() {
      _isConnected = true;
      _isConnecting = false;
      _isRecording = true;
    });

    _pulseController.repeat(reverse: true);
  }

  void _onTranscriptionDelta(Map<String, dynamic> data) {
    final delta = data['delta'] as String? ?? '';
    setState(() {
      if (_activeCard != null) {
        _activeCard!.partialText += delta;
      }
    });
    _scrollToBottom();
  }

  void _onTranscriptionDone(Map<String, dynamic> data) {
    final finalText = data['text'] as String? ?? '';
    setState(() {
      if (_activeCard != null && finalText.isNotEmpty) {
        _activeCard!.text +=
            (_activeCard!.text.isEmpty ? '' : '\n\n') + finalText;
        _activeCard!.partialText = '';
      }
    });
    _scrollToBottom();
  }

  Future<void> _startMicStream() async {
    final isMac = !kIsWeb && Platform.isMacOS;
    final stream = await _recorder.startStream(
      RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: kSampleRate,
        numChannels: 1,
        autoGain: !isMac,
        echoCancel: !isMac,
        noiseSuppress: !isMac,
      ),
    );

    _audioSubscription = stream.listen((data) {
      if (_channel != null && _isRecording) {
        final b64 = base64Encode(data);
        _channel!.sink.add(
          jsonEncode({'type': 'input_audio_buffer.append', 'audio': b64}),
        );
      }
    });
  }

  Future<void> _stopSession() async {
    _pulseController.stop();
    _pulseController.reset();

    _audioSubscription?.cancel();
    _audioSubscription = null;
    if (await _recorder.isRecording()) {
      await _recorder.stop();
    }

    if (_channel != null && _isConnected) {
      try {
        _channel!.sink.add(
          jsonEncode({'type': 'input_audio_buffer.commit', 'final': true}),
        );
        await Future.delayed(const Duration(seconds: 1));
      } catch (_) {}
    }

    _wsSubscription?.cancel();
    _wsSubscription = null;
    _channel?.sink.close();
    _channel = null;

    if (mounted) {
      setState(() {
        _isRecording = false;
        _isConnected = false;
        _isConnecting = false;
      });
    }
  }

  void _setError(String msg) {
    if (mounted) setState(() => _errorMessage = msg);
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: _cards.isEmpty ? _buildEmptyState() : _buildTimeline(),
    );
  }

  Widget _buildEmptyState() {
    return Stack(
      children: [
        Center(
          child: AnimatedOpacity(
            opacity: _isConnecting ? 0.4 : 0.12,
            duration: const Duration(milliseconds: 300),
            child: Text(
              _isConnecting ? '·  ·  ·' : _errorMessage ?? '',
              style: const TextStyle(
                fontSize: 14,
                color: Colors.white,
                fontWeight: FontWeight.w300,
                letterSpacing: 2,
              ),
            ),
          ),
        ),
        Positioned(left: 0, right: 0, bottom: 0, child: _buildBottomBar()),
      ],
    );
  }

  Widget _buildTimeline() {
    return Column(
      children: [
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildIndexBar(),
              Expanded(child: _buildCardList()),
            ],
          ),
        ),

        // Chat input (if a card is selected for chat)
        if (_chatCardIndex != null) _buildChatInput(),

        // Bottom controls
        _buildBottomBar(),
      ],
    );
  }

  Widget _buildIndexBar() {
    return Container(
      width: 48,
      padding: const EdgeInsets.only(top: 48),
      child: Column(
        children: [
          for (int i = 0; i < _cards.length; i++) ...[
            if (i > 0)
              Container(
                width: 1,
                height: 24,
                color: kAccent.withValues(alpha: 0.2),
              ),
            GestureDetector(
              onTap: () => _scrollToCard(i),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: i == _activeCardIndex ? 10 : 6,
                height: i == _activeCardIndex ? 10 : 6,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: i == _activeCardIndex
                      ? kAccent
                      : i == _chatCardIndex
                      ? kAiAccent.withValues(alpha: 0.6)
                      : kAccent.withValues(alpha: 0.3),
                  boxShadow: i == _activeCardIndex
                      ? [
                          BoxShadow(
                            color: kAccent.withValues(alpha: 0.3),
                            blurRadius: 8,
                          ),
                        ]
                      : null,
                ),
              ),
            ),
          ],
          if (_cards.isNotEmpty)
            Expanded(
              child: Container(
                width: 1,
                color: kAccent.withValues(alpha: 0.08),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCardList() {
    return SingleChildScrollView(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(8, 48, 32, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (int i = 0; i < _cards.length; i++) ...[
            if (i > 0) const SizedBox(height: 4),
            _buildCard(i),
          ],
        ],
      ),
    );
  }

  Widget _buildCard(int index) {
    final card = _cards[index];
    final isActive = index == _activeCardIndex;
    final isChatting = index == _chatCardIndex;

    return GestureDetector(
      onTap: () => _openChatForCard(index),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        decoration: BoxDecoration(
          color: isChatting
              ? kAiAccent.withValues(alpha: 0.03)
              : isActive
              ? Colors.white.withValues(alpha: 0.03)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isChatting
                ? kAiAccent.withValues(alpha: 0.15)
                : isActive
                ? kAccent.withValues(alpha: 0.15)
                : Colors.transparent,
            width: 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ─── Header: timestamp + indicators
            Row(
              children: [
                Text(
                  card.timestamp,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: kAccent.withValues(alpha: 0.7),
                    letterSpacing: 0.8,
                    fontFamily: 'SF Mono',
                  ),
                ),
                if (isActive && _isRecording) ...[
                  const SizedBox(width: 8),
                  AnimatedBuilder(
                    animation: _pulseController,
                    builder: (context, _) {
                      return Container(
                        width: 5,
                        height: 5,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: kAccent.withValues(
                            alpha: 0.3 + (_pulseController.value * 0.5),
                          ),
                        ),
                      );
                    },
                  ),
                ],
                const Spacer(),
                // Chat indicator
                if (isChatting)
                  Icon(
                    Icons.chat_bubble_outline_rounded,
                    size: 12,
                    color: kAiAccent.withValues(alpha: 0.5),
                  ),
              ],
            ),

            // ─── Transcription text
            if (card.hasContent) ...[
              const SizedBox(height: 10),
              if (card.text.isNotEmpty)
                SelectableText(
                  card.text,
                  style: const TextStyle(
                    fontSize: 15,
                    height: 1.7,
                    color: Colors.white,
                    fontWeight: FontWeight.w300,
                    letterSpacing: 0.15,
                  ),
                ),
              if (card.partialText.isNotEmpty) ...[
                if (card.text.isNotEmpty) const SizedBox(height: 4),
                Text(
                  card.partialText,
                  style: TextStyle(
                    fontSize: 15,
                    height: 1.7,
                    color: Colors.white.withValues(alpha: 0.35),
                    fontWeight: FontWeight.w300,
                    letterSpacing: 0.15,
                  ),
                ),
              ],
            ] else if (isActive && _isRecording) ...[
              const SizedBox(height: 10),
              Text(
                'listening…',
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.white.withValues(alpha: 0.15),
                  fontWeight: FontWeight.w300,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],

            // ─── Chat messages
            for (final chat in card.chatMessages) ...[
              const SizedBox(height: 14),
              // Divider
              Container(height: 1, color: kAiAccent.withValues(alpha: 0.08)),
              const SizedBox(height: 12),
              // User query
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Q ',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: kAccent.withValues(alpha: 0.6),
                      fontFamily: 'SF Mono',
                    ),
                  ),
                  Expanded(
                    child: Text(
                      chat.query,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.5,
                        color: Colors.white.withValues(alpha: 0.7),
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // AI response
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'A ',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: kAiAccent.withValues(alpha: 0.6),
                      fontFamily: 'SF Mono',
                    ),
                  ),
                  Expanded(
                    child: chat.response.isEmpty && chat.isStreaming
                        ? Text(
                            '·  ·  ·',
                            style: TextStyle(
                              fontSize: 13,
                              color: kAiAccent.withValues(alpha: 0.3),
                              letterSpacing: 2,
                            ),
                          )
                        : SelectableText(
                            chat.response,
                            style: TextStyle(
                              fontSize: 13,
                              height: 1.6,
                              color: kAiAccent.withValues(alpha: 0.85),
                              fontWeight: FontWeight.w300,
                            ),
                          ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildChatInput() {
    return Container(
      padding: const EdgeInsets.fromLTRB(60, 8, 24, 8),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: kAiAccent.withValues(alpha: 0.1), width: 1),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _chatController,
              focusNode: _chatFocus,
              style: TextStyle(
                fontSize: 13,
                color: Colors.white.withValues(alpha: 0.8),
                fontWeight: FontWeight.w300,
              ),
              decoration: InputDecoration(
                hintText: 'ask about this card…',
                hintStyle: TextStyle(
                  color: Colors.white.withValues(alpha: 0.15),
                  fontWeight: FontWeight.w300,
                  fontSize: 13,
                ),
                border: InputBorder.none,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
              ),
              onSubmitted: (_) {
                if (_chatCardIndex != null) {
                  _sendChatMessage(_chatCardIndex!);
                }
              },
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: () {
              if (_chatCardIndex != null) {
                _sendChatMessage(_chatCardIndex!);
              }
            },
            child: Icon(
              Icons.arrow_upward_rounded,
              size: 16,
              color: kAiAccent.withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(width: 12),
          GestureDetector(
            onTap: () => setState(() => _chatCardIndex = null),
            child: Icon(
              Icons.close_rounded,
              size: 14,
              color: Colors.white.withValues(alpha: 0.2),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomBar() {
    return Container(
      padding: const EdgeInsets.only(bottom: 16, top: 12),
      color: Colors.black,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // New card button
          if (_isRecording)
            GestureDetector(
              onTap: _createNewCard,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: kAccent.withValues(alpha: 0.25),
                    width: 1,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.add_rounded,
                      size: 14,
                      color: kAccent.withValues(alpha: 0.7),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      'new card',
                      style: TextStyle(
                        fontSize: 12,
                        color: kAccent.withValues(alpha: 0.7),
                        fontWeight: FontWeight.w400,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ],
                ),
              ),
            ),

          if (_isRecording) const SizedBox(width: 16),

          // Mic button
          GestureDetector(
            onTap: _isConnecting
                ? null
                : () {
                    if (_isRecording) {
                      _stopSession();
                    } else {
                      _startSession();
                    }
                  },
            child: AnimatedBuilder(
              animation: _pulseController,
              builder: (context, child) {
                final isActive = _isRecording;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: isActive ? 38 : 34,
                  height: isActive ? 38 : 34,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isActive
                        ? Color.lerp(
                            kAccent.withValues(alpha: 0.12),
                            kAccent.withValues(alpha: 0.2),
                            _pulseController.value,
                          )
                        : _isConnecting
                        ? Colors.white.withValues(alpha: 0.06)
                        : Colors.white.withValues(alpha: 0.08),
                    border: Border.all(
                      color: isActive
                          ? kAccent.withValues(alpha: 0.4)
                          : Colors.white.withValues(alpha: 0.12),
                      width: 1,
                    ),
                  ),
                  child: Icon(
                    isActive
                        ? Icons.stop_rounded
                        : _isConnecting
                        ? Icons.more_horiz_rounded
                        : Icons.mic_none_rounded,
                    color: isActive
                        ? kAccent.withValues(alpha: 0.9)
                        : Colors.white.withValues(alpha: 0.35),
                    size: isActive ? 16 : 15,
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
