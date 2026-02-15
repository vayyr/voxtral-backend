// ─── Data Models ────────────────────────────────────────────────────────────

class ChatMessage {
  String query;
  String response;
  bool isStreaming;

  ChatMessage({
    required this.query,
    this.response = '',
    this.isStreaming = true,
  });

  Map<String, dynamic> toJson() => {'query': query, 'response': response};

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
    query: json['query'] as String,
    response: json['response'] as String? ?? '',
    isStreaming: false,
  );
}

class TranscriptCard {
  final DateTime createdAt;
  String title;
  String text;
  String partialText;
  final List<ChatMessage> chatMessages;

  TranscriptCard({
    required this.createdAt,
    this.title = '',
    this.text = '',
    this.partialText = '',
  }) : chatMessages = [];

  String get timestamp {
    final h = createdAt.hour.toString().padLeft(2, '0');
    final m = createdAt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  int get wordCount {
    final allText = '$text $partialText'.trim();
    if (allText.isEmpty) return 0;
    return allText.split(RegExp(r'\s+')).length;
  }

  String get durationLabel {
    final elapsed = DateTime.now().difference(createdAt);
    if (elapsed.inMinutes < 1) return '<1m';
    if (elapsed.inHours < 1) return '${elapsed.inMinutes}m';
    return '${elapsed.inHours}h ${elapsed.inMinutes % 60}m';
  }

  bool get isEmpty => text.isEmpty && partialText.isEmpty;
  bool get hasContent => text.isNotEmpty || partialText.isNotEmpty;
  String get displayTitle => title.isNotEmpty ? title : '';

  Map<String, dynamic> toJson() {
    // Merge partial into text when saving — nothing is ever lost
    final savedText = partialText.isNotEmpty
        ? (text.isEmpty ? partialText : '$text\n\n$partialText')
        : text;
    return {
      'createdAt': createdAt.toIso8601String(),
      'title': title,
      'text': savedText,
      'chatMessages': chatMessages.map((m) => m.toJson()).toList(),
    };
  }

  factory TranscriptCard.fromJson(Map<String, dynamic> json) {
    final card = TranscriptCard(
      createdAt: DateTime.parse(json['createdAt'] as String),
      title: json['title'] as String? ?? '',
      text: json['text'] as String? ?? '',
    );
    final msgs = json['chatMessages'] as List?;
    if (msgs != null) {
      card.chatMessages.addAll(
        msgs.map((m) => ChatMessage.fromJson(m as Map<String, dynamic>)),
      );
    }
    return card;
  }
}

class Session {
  final String id;
  String name;
  final DateTime createdAt;
  final List<TranscriptCard> cards;

  Session({required this.id, this.name = '', required this.createdAt})
    : cards = [];

  String get displayName {
    if (name.isNotEmpty) return name;
    final h = createdAt.hour.toString().padLeft(2, '0');
    final m = createdAt.minute.toString().padLeft(2, '0');
    final month = createdAt.month.toString().padLeft(2, '0');
    final day = createdAt.day.toString().padLeft(2, '0');
    return '$month/$day $h:$m';
  }

  int get cardCount => cards.length;
  int get totalWords => cards.fold(0, (sum, c) => sum + c.wordCount);

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'createdAt': createdAt.toIso8601String(),
    'cards': cards.map((c) => c.toJson()).toList(),
  };

  factory Session.fromJson(Map<String, dynamic> json) {
    final session = Session(
      id: json['id'] as String,
      name: json['name'] as String? ?? '',
      createdAt: DateTime.parse(json['createdAt'] as String),
    );
    final cards = json['cards'] as List?;
    if (cards != null) {
      session.cards.addAll(
        cards.map((c) => TranscriptCard.fromJson(c as Map<String, dynamic>)),
      );
    }
    return session;
  }
}

class SessionMeta {
  final String id;
  final String name;
  final DateTime createdAt;
  final int cardCount;

  SessionMeta({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.cardCount,
  });

  String get displayName {
    if (name.isNotEmpty) return name;
    final h = createdAt.hour.toString().padLeft(2, '0');
    final m = createdAt.minute.toString().padLeft(2, '0');
    final month = createdAt.month.toString().padLeft(2, '0');
    final day = createdAt.day.toString().padLeft(2, '0');
    return '$month/$day $h:$m';
  }
}
