import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'models.dart';
import 'storage.dart';
import 'llm.dart';

// ─── Configuration ──────────────────────────────────────────────────────────
const String kServerHost = '100.111.74.127';
const int kServerPort = 8000;
const String kModel = 'mistralai/Voxtral-Mini-4B-Realtime-2602';
const int kSampleRate = 16000;

// ─── Colors ─────────────────────────────────────────────────────────────────
const Color kAccent = Color(0xFFD4A574);
const Color kAiAccent = Color(0xFF7AA2D4);

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
  // ─── State ──────────────────────────────────────────────────────────────
  Session? _session;
  bool _isRecording = false;
  bool _isConnected = false;
  bool _isConnecting = false;
  int _activeCardIndex = -1;
  int? _chatCardIndex;
  bool _useFullContext = false;
  String? _errorMessage;
  int? _editingTitleIndex;
  int? _copiedCardIndex;

  // Overlays
  bool _showNavigator = false;
  bool _isSearching = false;
  String _searchQuery = '';
  List<SessionMeta> _navigatorSessions = [];

  // Services
  final StorageService _storage = StorageService();
  final LlmService _llm = LlmService();

  // Audio & WebSocket
  final AudioRecorder _recorder = AudioRecorder();
  WebSocketChannel? _channel;
  StreamSubscription? _audioSubscription;
  StreamSubscription? _wsSubscription;

  // Controllers
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _chatController = TextEditingController();
  final FocusNode _chatFocus = FocusNode();
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  final TextEditingController _navigatorController = TextEditingController();
  final TextEditingController _titleController = TextEditingController();
  late AnimationController _pulseController;
  Timer? _saveTimer;
  Timer? _copiedTimer;
  final Map<int, GlobalKey> _cardKeys = {};

  // ─── Lifecycle ──────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _loadLastSession();
  }

  @override
  void dispose() {
    _stopSession();
    _recorder.dispose();
    _pulseController.dispose();
    _scrollController.dispose();
    _chatController.dispose();
    _chatFocus.dispose();
    _searchController.dispose();
    _searchFocus.dispose();
    _navigatorController.dispose();
    _titleController.dispose();
    _saveTimer?.cancel();
    _copiedTimer?.cancel();
    super.dispose();
  }

  // ─── Session management ─────────────────────────────────────────────────

  Future<void> _loadLastSession() async {
    final lastId = await _storage.getLastSessionId();
    if (lastId != null) {
      final session = await _storage.loadSession(lastId);
      if (session != null) {
        setState(() {
          _session = session;
          _activeCardIndex = session.cards.isEmpty
              ? -1
              : session.cards.length - 1;
          _cardKeys.clear();
        });
        return;
      }
    }
    _createNewSession();
  }

  void _createNewSession() {
    if (_isRecording) _stopSession();

    final session = Session(
      id: DateTime.now().millisecondsSinceEpoch.toRadixString(36),
      createdAt: DateTime.now(),
    );

    setState(() {
      _session = session;
      _activeCardIndex = -1;
      _chatCardIndex = null;
      _cardKeys.clear();
      _showNavigator = false;
    });

    _storage.saveSession(session);
    _storage.saveLastSessionId(session.id);
  }

  Future<void> _switchToSession(String id) async {
    if (_session != null) {
      await _storage.saveSession(_session!);
    }
    if (_isRecording) await _stopSession();

    final session = await _storage.loadSession(id);
    if (session != null) {
      setState(() {
        _session = session;
        _activeCardIndex = session.cards.isEmpty
            ? -1
            : session.cards.length - 1;
        _chatCardIndex = null;
        _cardKeys.clear();
        _showNavigator = false;
      });
      _storage.saveLastSessionId(id);
    }
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), () {
      if (_session != null) _storage.saveSession(_session!);
    });
  }

  // ─── Card management ──────────────────────────────────────────────────

  void _createNewCard() {
    if (_session == null) return;

    setState(() {
      _session!.cards.add(TranscriptCard(createdAt: DateTime.now()));
      _activeCardIndex = _session!.cards.length - 1;
    });
    _scheduleSave();
    _scrollToBottom();
  }

  void _generateTitle(int index) {
    final card = _session!.cards[index];
    if (!card.hasContent) return;
    final text = '${card.text} ${card.partialText}'.trim();
    _llm.summarize(text).then((summary) {
      if (mounted && summary.isNotEmpty) {
        setState(() => card.title = summary);
        _scheduleSave();
      }
    });
  }

  TranscriptCard? get _activeCard {
    if (_session == null) return null;
    if (_activeCardIndex < 0 || _activeCardIndex >= _session!.cards.length) {
      return null;
    }
    return _session!.cards[_activeCardIndex];
  }

  GlobalKey _keyForCard(int index) {
    _cardKeys.putIfAbsent(index, () => GlobalKey());
    return _cardKeys[index]!;
  }

  void _scrollToCard(int index) {
    final key = _cardKeys[index];
    if (key?.currentContext != null) {
      Scrollable.ensureVisible(
        key!.currentContext!,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOutCubic,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart,
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

  void _copyCard(int index) {
    final card = _session!.cards[index];
    Clipboard.setData(ClipboardData(text: card.text));
    setState(() => _copiedCardIndex = index);
    _copiedTimer?.cancel();
    _copiedTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copiedCardIndex = null);
    });
  }

  void _startEditingTitle(int index) {
    final card = _session!.cards[index];
    _titleController.text = card.title;
    setState(() => _editingTitleIndex = index);
  }

  void _finishEditingTitle() {
    if (_editingTitleIndex != null && _session != null) {
      final card = _session!.cards[_editingTitleIndex!];
      card.title = _titleController.text.trim();
      _scheduleSave();
    }
    setState(() => _editingTitleIndex = null);
  }

  // ─── Quick actions ────────────────────────────────────────────────────

  void _quickAction(int cardIndex, String action) {
    final card = _session!.cards[cardIndex];
    final chatMsg = ChatMessage(query: action);
    setState(() => card.chatMessages.add(chatMsg));
    _scrollToBottom();

    final context = _useFullContext
        ? _llm.buildFullContext(_session!.cards)
        : '${card.text}${card.partialText.isNotEmpty ? '\n${card.partialText}' : ''}';

    _llm.streamChat(
      context: context,
      query: action,
      onDelta: (d) => setState(() => chatMsg.response += d),
      onDone: () {
        setState(() => chatMsg.isStreaming = false);
        _scheduleSave();
        _scrollToBottom();
      },
      onError: (e) {
        setState(() {
          chatMsg.response = 'Error: $e';
          chatMsg.isStreaming = false;
        });
      },
    );
  }

  // ─── LLM Chat ─────────────────────────────────────────────────────────

  Future<void> _sendChatMessage(int cardIndex) async {
    final query = _chatController.text.trim();
    if (query.isEmpty || _session == null) return;

    final card = _session!.cards[cardIndex];
    final chatMsg = ChatMessage(query: query);
    setState(() {
      card.chatMessages.add(chatMsg);
      _chatController.clear();
    });
    _scrollToBottom();

    final context = _useFullContext
        ? _llm.buildFullContext(_session!.cards)
        : '${card.text}${card.partialText.isNotEmpty ? '\n${card.partialText}' : ''}';

    _llm.streamChat(
      context: context,
      query: query,
      onDelta: (d) {
        setState(() => chatMsg.response += d);
        _scrollToBottom();
      },
      onDone: () {
        setState(() => chatMsg.isStreaming = false);
        _scheduleSave();
      },
      onError: (e) {
        debugPrint('LLM error: $e');
        setState(() {
          chatMsg.response = 'Error: $e';
          chatMsg.isStreaming = false;
        });
      },
    );
  }

  // ─── Transcription session ────────────────────────────────────────────

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

    // Create first card if needed
    if (_session != null &&
        (_session!.cards.isEmpty ||
            _activeCard == null ||
            !_activeCard!.isEmpty)) {
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
    _scheduleSave();
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

    // Commit final audio
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

    _scheduleSave();
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

  // ─── Search ───────────────────────────────────────────────────────────

  void _toggleSearch() {
    setState(() {
      _isSearching = !_isSearching;
      if (_isSearching) {
        _searchController.clear();
        _searchQuery = '';
        Future.delayed(const Duration(milliseconds: 100), () {
          _searchFocus.requestFocus();
        });
      }
    });
  }

  int get _searchMatchCount {
    if (_searchQuery.isEmpty || _session == null) return 0;
    final q = _searchQuery.toLowerCase();
    int count = 0;
    for (final card in _session!.cards) {
      if (card.text.toLowerCase().contains(q)) count++;
    }
    return count;
  }

  // ─── Navigator ────────────────────────────────────────────────────────

  Future<void> _toggleNavigator() async {
    if (_showNavigator) {
      setState(() => _showNavigator = false);
      return;
    }

    final sessions = await _storage.listSessions();
    setState(() {
      _navigatorSessions = sessions;
      _navigatorController.clear();
      _showNavigator = true;
    });
  }

  void _dismissOverlays() {
    if (_showNavigator) {
      setState(() => _showNavigator = false);
    } else if (_isSearching) {
      setState(() {
        _isSearching = false;
        _searchQuery = '';
      });
    } else if (_chatCardIndex != null) {
      setState(() => _chatCardIndex = null);
    }
  }

  // ─── Text highlight helper ────────────────────────────────────────────

  TextSpan _highlightText(String text, TextStyle style) {
    if (_searchQuery.isEmpty || !_isSearching) {
      return TextSpan(text: text, style: style);
    }
    final query = _searchQuery.toLowerCase();
    final lower = text.toLowerCase();
    final spans = <TextSpan>[];
    int start = 0;

    while (true) {
      final index = lower.indexOf(query, start);
      if (index == -1) break;
      if (index > start) {
        spans.add(TextSpan(text: text.substring(start, index), style: style));
      }
      spans.add(
        TextSpan(
          text: text.substring(index, index + query.length),
          style: style.copyWith(
            backgroundColor: kAccent.withValues(alpha: 0.35),
            color: Colors.white,
          ),
        ),
      );
      start = index + query.length;
    }

    if (start < text.length) {
      spans.add(TextSpan(text: text.substring(start), style: style));
    }

    if (spans.isEmpty) return TextSpan(text: text, style: style);
    return TextSpan(children: spans);
  }

  // ─── Build ────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyN, meta: true):
            _createNewCard,
        const SingleActivator(LogicalKeyboardKey.keyN, meta: true, shift: true):
            _createNewSession,
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true):
            _toggleNavigator,
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true):
            _toggleSearch,
        const SingleActivator(LogicalKeyboardKey.escape): _dismissOverlays,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            children: [
              _session == null || (_session!.cards.isEmpty && !_isRecording)
                  ? _buildEmptyState()
                  : _buildTimeline(),
              if (_isSearching) _buildSearchOverlay(),
              if (_showNavigator) _buildNavigatorOverlay(),
            ],
          ),
        ),
      ),
    );
  }

  // ─── Empty state ──────────────────────────────────────────────────────

  Widget _buildEmptyState() {
    return Column(
      children: [
        Expanded(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedOpacity(
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
                const SizedBox(height: 48),
                Text(
                  '⌘K sessions  ·  ⌘⇧N new',
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.white.withValues(alpha: 0.08),
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
          ),
        ),
        _buildBottomBar(),
      ],
    );
  }

  // ─── Timeline ─────────────────────────────────────────────────────────

  Widget _buildTimeline() {
    return Column(
      children: [
        Expanded(child: _buildCardList()),
        if (_chatCardIndex != null) _buildChatInput(),
        _buildBottomBar(),
      ],
    );
  }

  Widget _buildCardList() {
    return SingleChildScrollView(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(0, 40, 24, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (int i = 0; i < _session!.cards.length; i++) _buildCardRow(i),
        ],
      ),
    );
  }

  Widget _buildCardRow(int index) {
    final card = _session!.cards[index];
    final isActive = index == _activeCardIndex;
    final isChatting = index == _chatCardIndex;

    return Container(
      key: _keyForCard(index),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ─── Index bar (dot + line) ───────────────────
            SizedBox(
              width: 48,
              child: Column(
                children: [
                  // Connecting line (top)
                  Expanded(
                    child: Container(
                      width: 1,
                      color: index == 0
                          ? Colors.transparent
                          : kAccent.withValues(alpha: 0.15),
                    ),
                  ),
                  // Dot
                  GestureDetector(
                    onTap: () => _scrollToCard(index),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      width: isActive ? 10 : 6,
                      height: isActive ? 10 : 6,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isActive
                            ? kAccent
                            : isChatting
                            ? kAiAccent.withValues(alpha: 0.6)
                            : kAccent.withValues(alpha: 0.3),
                        boxShadow: isActive
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
                  // Connecting line (bottom)
                  Expanded(
                    child: Container(
                      width: 1,
                      color: kAccent.withValues(alpha: 0.15),
                    ),
                  ),
                ],
              ),
            ),

            // ─── Card content ─────────────────────────────
            Expanded(child: _buildCard(index, card, isActive, isChatting)),
          ],
        ),
      ),
    );
  }

  Widget _buildCard(
    int index,
    TranscriptCard card,
    bool isActive,
    bool isChatting,
  ) {
    return GestureDetector(
      onTap: () => _openChatForCard(index),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: const EdgeInsets.only(bottom: 2),
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 14),
        decoration: BoxDecoration(
          color: isChatting
              ? kAiAccent.withValues(alpha: 0.03)
              : isActive
              ? Colors.white.withValues(alpha: 0.02)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isChatting
                ? kAiAccent.withValues(alpha: 0.12)
                : isActive
                ? kAccent.withValues(alpha: 0.1)
                : Colors.transparent,
            width: 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ─── Header row ──────────────────────────────
            Row(
              children: [
                // Timestamp
                Text(
                  card.timestamp,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: kAccent.withValues(alpha: 0.6),
                    letterSpacing: 0.8,
                    fontFamily: 'SF Mono',
                  ),
                ),
                // Live indicator
                if (isActive && _isRecording) ...[
                  const SizedBox(width: 8),
                  AnimatedBuilder(
                    animation: _pulseController,
                    builder: (context, _) => Container(
                      width: 5,
                      height: 5,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: kAccent.withValues(
                          alpha: 0.3 + (_pulseController.value * 0.5),
                        ),
                      ),
                    ),
                  ),
                ],
                // Metadata
                if (card.hasContent) ...[
                  const SizedBox(width: 10),
                  Text(
                    '${card.wordCount}w · ${card.durationLabel}',
                    style: TextStyle(
                      fontSize: 10,
                      color: Colors.white.withValues(alpha: 0.12),
                      fontFamily: 'SF Mono',
                    ),
                  ),
                ],
                const Spacer(),
                // Copy button
                if (card.hasContent)
                  GestureDetector(
                    onTap: () => _copyCard(index),
                    child: Icon(
                      _copiedCardIndex == index
                          ? Icons.check_rounded
                          : Icons.copy_rounded,
                      size: 12,
                      color: _copiedCardIndex == index
                          ? kAccent.withValues(alpha: 0.6)
                          : Colors.white.withValues(alpha: 0.12),
                    ),
                  ),
              ],
            ),

            // ─── Title ────────────────────────────────────
            if (_editingTitleIndex == index) ...[
              const SizedBox(height: 6),
              TextField(
                controller: _titleController,
                autofocus: true,
                style: TextStyle(
                  fontSize: 13,
                  color: kAccent.withValues(alpha: 0.9),
                  fontWeight: FontWeight.w500,
                ),
                decoration: InputDecoration(
                  hintText: 'card title…',
                  hintStyle: TextStyle(
                    color: Colors.white.withValues(alpha: 0.1),
                    fontSize: 13,
                  ),
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: EdgeInsets.zero,
                ),
                onSubmitted: (_) => _finishEditingTitle(),
                onTapOutside: (_) => _finishEditingTitle(),
              ),
            ] else if (card.title.isNotEmpty) ...[
              const SizedBox(height: 6),
              GestureDetector(
                onDoubleTap: () => _startEditingTitle(index),
                child: Text(
                  card.title,
                  style: TextStyle(
                    fontSize: 13,
                    color: kAccent.withValues(alpha: 0.7),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ] else if (card.hasContent) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  GestureDetector(
                    onTap: () => _generateTitle(index),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: kAccent.withValues(alpha: 0.12),
                          width: 1,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.auto_awesome_rounded,
                            size: 10,
                            color: kAccent.withValues(alpha: 0.4),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            'generate',
                            style: TextStyle(
                              fontSize: 10,
                              color: kAccent.withValues(alpha: 0.4),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () => _startEditingTitle(index),
                    child: Text(
                      '+ title',
                      style: TextStyle(
                        fontSize: 10,
                        color: Colors.white.withValues(alpha: 0.08),
                      ),
                    ),
                  ),
                ],
              ),
            ],

            // ─── Transcription text ──────────────────────
            if (card.hasContent) ...[
              const SizedBox(height: 10),
              if (card.text.isNotEmpty)
                SelectableText.rich(
                  _highlightText(
                    card.text,
                    const TextStyle(
                      fontSize: 15,
                      height: 1.7,
                      color: Colors.white,
                      fontWeight: FontWeight.w300,
                      letterSpacing: 0.15,
                    ),
                  ),
                ),
              if (card.partialText.isNotEmpty) ...[
                if (card.text.isNotEmpty) const SizedBox(height: 4),
                Text(
                  card.partialText,
                  style: TextStyle(
                    fontSize: 15,
                    height: 1.7,
                    color: Colors.white,
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
                  color: Colors.white.withValues(alpha: 0.12),
                  fontWeight: FontWeight.w300,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],

            // ─── Quick actions ───────────────────────────
            if (card.hasContent && isChatting) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  _quickActionChip('summarize', index),
                  const SizedBox(width: 8),
                  _quickActionChip('action items', index),
                  const SizedBox(width: 8),
                  _quickActionChip('key points', index),
                ],
              ),
            ],

            // ─── Chat messages ───────────────────────────
            for (final chat in card.chatMessages) ...[
              const SizedBox(height: 14),
              Container(height: 1, color: kAiAccent.withValues(alpha: 0.06)),
              const SizedBox(height: 12),
              // Query
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Q ',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: kAccent.withValues(alpha: 0.5),
                      fontFamily: 'SF Mono',
                    ),
                  ),
                  Expanded(
                    child: Text(
                      chat.query,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.5,
                        color: Colors.white.withValues(alpha: 0.6),
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // Response
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'A ',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: kAiAccent.withValues(alpha: 0.5),
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
                        : MarkdownBody(
                            data: chat.response,
                            selectable: true,
                            styleSheet: MarkdownStyleSheet(
                              p: TextStyle(
                                fontSize: 13,
                                height: 1.6,
                                color: kAiAccent.withValues(alpha: 0.8),
                                fontWeight: FontWeight.w300,
                              ),
                              h1: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                                color: kAiAccent.withValues(alpha: 0.9),
                              ),
                              h2: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: kAiAccent.withValues(alpha: 0.9),
                              ),
                              h3: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: kAiAccent.withValues(alpha: 0.85),
                              ),
                              strong: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: kAiAccent.withValues(alpha: 0.9),
                              ),
                              em: TextStyle(
                                fontSize: 13,
                                fontStyle: FontStyle.italic,
                                color: kAiAccent.withValues(alpha: 0.7),
                              ),
                              listBullet: TextStyle(
                                fontSize: 13,
                                color: kAiAccent.withValues(alpha: 0.5),
                              ),
                              code: TextStyle(
                                fontSize: 12,
                                fontFamily: 'SF Mono',
                                color: kAccent.withValues(alpha: 0.8),
                                backgroundColor: Colors.white.withValues(
                                  alpha: 0.04,
                                ),
                              ),
                              codeblockDecoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.03),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.06),
                                ),
                              ),
                              blockquoteDecoration: BoxDecoration(
                                border: Border(
                                  left: BorderSide(
                                    color: kAiAccent.withValues(alpha: 0.2),
                                    width: 2,
                                  ),
                                ),
                              ),
                              horizontalRuleDecoration: BoxDecoration(
                                border: Border(
                                  top: BorderSide(
                                    color: Colors.white.withValues(alpha: 0.06),
                                  ),
                                ),
                              ),
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

  Widget _quickActionChip(String label, int cardIndex) {
    return GestureDetector(
      onTap: () => _quickAction(cardIndex, label),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: kAiAccent.withValues(alpha: 0.15),
            width: 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: kAiAccent.withValues(alpha: 0.5),
            fontWeight: FontWeight.w400,
          ),
        ),
      ),
    );
  }

  // ─── Chat input ───────────────────────────────────────────────────────

  Widget _buildChatInput() {
    return Container(
      padding: const EdgeInsets.fromLTRB(56, 8, 24, 8),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: kAiAccent.withValues(alpha: 0.08), width: 1),
        ),
      ),
      child: Row(
        children: [
          // Full context toggle
          GestureDetector(
            onTap: () => setState(() => _useFullContext = !_useFullContext),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: _useFullContext
                    ? kAiAccent.withValues(alpha: 0.1)
                    : Colors.transparent,
                border: Border.all(
                  color: _useFullContext
                      ? kAiAccent.withValues(alpha: 0.25)
                      : Colors.white.withValues(alpha: 0.06),
                  width: 1,
                ),
              ),
              child: Text(
                _useFullContext ? 'all' : 'card',
                style: TextStyle(
                  fontSize: 10,
                  color: _useFullContext
                      ? kAiAccent.withValues(alpha: 0.7)
                      : Colors.white.withValues(alpha: 0.2),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          // Text field
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
                hintText:
                    'ask about this ${_useFullContext ? 'session' : 'card'}…',
                hintStyle: TextStyle(
                  color: Colors.white.withValues(alpha: 0.12),
                  fontWeight: FontWeight.w300,
                  fontSize: 13,
                ),
                border: InputBorder.none,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
              ),
              onSubmitted: (_) {
                if (_chatCardIndex != null) _sendChatMessage(_chatCardIndex!);
              },
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: () {
              if (_chatCardIndex != null) _sendChatMessage(_chatCardIndex!);
            },
            child: Icon(
              Icons.arrow_upward_rounded,
              size: 16,
              color: kAiAccent.withValues(alpha: 0.4),
            ),
          ),
          const SizedBox(width: 12),
          GestureDetector(
            onTap: () => setState(() => _chatCardIndex = null),
            child: Icon(
              Icons.close_rounded,
              size: 14,
              color: Colors.white.withValues(alpha: 0.15),
            ),
          ),
        ],
      ),
    );
  }

  // ─── Bottom bar ───────────────────────────────────────────────────────

  Widget _buildBottomBar() {
    return Container(
      padding: const EdgeInsets.only(bottom: 14, top: 10),
      color: Colors.black,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Session indicator
          GestureDetector(
            onTap: _toggleNavigator,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.06),
                  width: 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.folder_outlined,
                    size: 12,
                    color: Colors.white.withValues(alpha: 0.2),
                  ),
                  const SizedBox(width: 5),
                  Text(
                    _session?.displayName ?? '',
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.white.withValues(alpha: 0.25),
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(width: 12),

          // New card button
          if (_isRecording)
            GestureDetector(
              onTap: _createNewCard,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: kAccent.withValues(alpha: 0.2),
                    width: 1,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.add_rounded,
                      size: 13,
                      color: kAccent.withValues(alpha: 0.6),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '⌘N',
                      style: TextStyle(
                        fontSize: 11,
                        color: kAccent.withValues(alpha: 0.4),
                        fontWeight: FontWeight.w400,
                        fontFamily: 'SF Mono',
                      ),
                    ),
                  ],
                ),
              ),
            ),

          if (_isRecording) const SizedBox(width: 12),

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
                  width: isActive ? 36 : 32,
                  height: isActive ? 36 : 32,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isActive
                        ? Color.lerp(
                            kAccent.withValues(alpha: 0.1),
                            kAccent.withValues(alpha: 0.18),
                            _pulseController.value,
                          )
                        : _isConnecting
                        ? Colors.white.withValues(alpha: 0.05)
                        : Colors.white.withValues(alpha: 0.07),
                    border: Border.all(
                      color: isActive
                          ? kAccent.withValues(alpha: 0.35)
                          : Colors.white.withValues(alpha: 0.1),
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
                        ? kAccent.withValues(alpha: 0.8)
                        : Colors.white.withValues(alpha: 0.3),
                    size: isActive ? 15 : 14,
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // ─── Search overlay ───────────────────────────────────────────────────

  Widget _buildSearchOverlay() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: const EdgeInsets.fromLTRB(56, 12, 24, 12),
        color: Colors.black,
        child: Row(
          children: [
            Icon(
              Icons.search_rounded,
              size: 14,
              color: Colors.white.withValues(alpha: 0.2),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: _searchController,
                focusNode: _searchFocus,
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.white.withValues(alpha: 0.8),
                  fontWeight: FontWeight.w300,
                ),
                decoration: InputDecoration(
                  hintText: 'search…',
                  hintStyle: TextStyle(
                    color: Colors.white.withValues(alpha: 0.12),
                    fontSize: 13,
                  ),
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 6),
                ),
                onChanged: (v) => setState(() => _searchQuery = v),
              ),
            ),
            if (_searchQuery.isNotEmpty) ...[
              const SizedBox(width: 8),
              Text(
                '$_searchMatchCount match${_searchMatchCount == 1 ? '' : 'es'}',
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.white.withValues(alpha: 0.2),
                  fontFamily: 'SF Mono',
                ),
              ),
            ],
            const SizedBox(width: 12),
            GestureDetector(
              onTap: () => setState(() {
                _isSearching = false;
                _searchQuery = '';
              }),
              child: Icon(
                Icons.close_rounded,
                size: 14,
                color: Colors.white.withValues(alpha: 0.2),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── Session navigator overlay ────────────────────────────────────────

  Widget _buildNavigatorOverlay() {
    final filter = _navigatorController.text.toLowerCase();
    final filtered = filter.isEmpty
        ? _navigatorSessions
        : _navigatorSessions
              .where((s) => s.displayName.toLowerCase().contains(filter))
              .toList();

    return Positioned.fill(
      child: GestureDetector(
        onTap: () => setState(() => _showNavigator = false),
        child: Container(
          color: Colors.black.withValues(alpha: 0.85),
          child: Center(
            child: GestureDetector(
              onTap: () {}, // absorb taps within
              child: Container(
                width: 380,
                constraints: const BoxConstraints(maxHeight: 420),
                decoration: BoxDecoration(
                  color: const Color(0xFF0A0A0A),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.06),
                    width: 1,
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Search field
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                      child: TextField(
                        controller: _navigatorController,
                        autofocus: true,
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.white.withValues(alpha: 0.8),
                          fontWeight: FontWeight.w300,
                        ),
                        decoration: InputDecoration(
                          hintText: 'find session…',
                          hintStyle: TextStyle(
                            color: Colors.white.withValues(alpha: 0.15),
                            fontSize: 14,
                          ),
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding: EdgeInsets.zero,
                          prefixIcon: Padding(
                            padding: const EdgeInsets.only(right: 10),
                            child: Icon(
                              Icons.search_rounded,
                              size: 16,
                              color: Colors.white.withValues(alpha: 0.2),
                            ),
                          ),
                          prefixIconConstraints: const BoxConstraints(
                            minWidth: 0,
                            minHeight: 0,
                          ),
                        ),
                        onChanged: (_) => setState(() {}),
                        onSubmitted: (_) {
                          if (filtered.isNotEmpty) {
                            _switchToSession(filtered.first.id);
                          }
                        },
                      ),
                    ),
                    Container(
                      height: 1,
                      color: Colors.white.withValues(alpha: 0.04),
                    ),
                    // New session button
                    GestureDetector(
                      onTap: () {
                        setState(() => _showNavigator = false);
                        _createNewSession();
                      },
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.add_rounded,
                              size: 14,
                              color: kAccent.withValues(alpha: 0.6),
                            ),
                            const SizedBox(width: 10),
                            Text(
                              'New session',
                              style: TextStyle(
                                fontSize: 13,
                                color: kAccent.withValues(alpha: 0.7),
                                fontWeight: FontWeight.w400,
                              ),
                            ),
                            const Spacer(),
                            Text(
                              '⌘⇧N',
                              style: TextStyle(
                                fontSize: 10,
                                color: Colors.white.withValues(alpha: 0.1),
                                fontFamily: 'SF Mono',
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Container(
                      height: 1,
                      color: Colors.white.withValues(alpha: 0.04),
                    ),
                    // Session list
                    Flexible(
                      child: ListView.builder(
                        shrinkWrap: true,
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        itemCount: filtered.length,
                        itemBuilder: (context, i) {
                          final s = filtered[i];
                          final isCurrent = s.id == _session?.id;
                          return GestureDetector(
                            onTap: () => _switchToSession(s.id),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 9,
                              ),
                              color: isCurrent
                                  ? Colors.white.withValues(alpha: 0.03)
                                  : Colors.transparent,
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          s.displayName,
                                          style: TextStyle(
                                            fontSize: 13,
                                            color: isCurrent
                                                ? kAccent.withValues(alpha: 0.8)
                                                : Colors.white.withValues(
                                                    alpha: 0.6,
                                                  ),
                                            fontWeight: FontWeight.w400,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ],
                                    ),
                                  ),
                                  Text(
                                    '${s.cardCount} card${s.cardCount == 1 ? '' : 's'}',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: Colors.white.withValues(
                                        alpha: 0.12,
                                      ),
                                      fontFamily: 'SF Mono',
                                    ),
                                  ),
                                  if (!isCurrent) ...[
                                    const SizedBox(width: 12),
                                    GestureDetector(
                                      onTap: () async {
                                        await _storage.deleteSession(s.id);
                                        final sessions = await _storage
                                            .listSessions();
                                        setState(
                                          () => _navigatorSessions = sessions,
                                        );
                                      },
                                      child: Icon(
                                        Icons.close_rounded,
                                        size: 12,
                                        color: Colors.white.withValues(
                                          alpha: 0.1,
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
