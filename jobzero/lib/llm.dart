import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'models.dart';

const String kLlmHost = '192.168.1.156';
const int kLlmPort = 1234;

class LlmService {
  Future<void> streamChat({
    required String context,
    required String query,
    required void Function(String delta) onDelta,
    required void Function() onDone,
    required void Function(String error) onError,
  }) async {
    try {
      final client = HttpClient();
      final uri = Uri.parse('http://$kLlmHost:$kLlmPort/v1/chat/completions');
      final request = await client.postUrl(uri);
      request.headers.contentType = ContentType.json;

      request.write(
        jsonEncode({
          'messages': [
            {
              'role': 'system',
              'content':
                  'You are a helpful assistant analyzing a live transcription. Be concise and direct.',
            },
            {
              'role': 'user',
              'content':
                  'Here is the transcription:\n\n$context\n\nQuestion: $query',
            },
          ],
          'stream': true,
          'temperature': 0.7,
          'max_tokens': 1024,
        }),
      );

      final response = await request.close();
      String buffer = '';

      await for (final chunk in response.transform(utf8.decoder)) {
        buffer += chunk;
        final lines = buffer.split('\n');
        buffer = lines.removeLast();

        for (final line in lines) {
          if (line.startsWith('data: ')) {
            final data = line.substring(6).trim();
            if (data == '[DONE]') {
              onDone();
              client.close();
              return;
            }
            try {
              final json = jsonDecode(data) as Map<String, dynamic>;
              final choices = json['choices'] as List?;
              if (choices != null && choices.isNotEmpty) {
                final delta = choices[0]['delta'] as Map<String, dynamic>?;
                final content = delta?['content'] as String?;
                if (content != null) onDelta(content);
              }
            } catch (_) {}
          }
        }
      }

      onDone();
      client.close();
    } catch (e) {
      debugPrint('LLM stream error: $e');
      onError('$e');
    }
  }

  /// Non-streaming summary — returns a brief title.
  Future<String> summarize(String text) async {
    try {
      final client = HttpClient();
      final uri = Uri.parse('http://$kLlmHost:$kLlmPort/v1/chat/completions');
      final request = await client.postUrl(uri);
      request.headers.contentType = ContentType.json;

      request.write(
        jsonEncode({
          'messages': [
            {
              'role': 'system',
              'content':
                  'Summarize the following text in exactly 3 to 5 words. Reply with ONLY the summary, nothing else.',
            },
            {'role': 'user', 'content': text},
          ],
          'temperature': 0.3,
        }),
      );

      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      debugPrint('Summarize raw response: $body');
      final json = jsonDecode(body) as Map<String, dynamic>;
      final choices = json['choices'] as List;
      final content =
          (choices[0]['message']['content'] as String?)?.trim() ?? '';
      debugPrint('Summarize result: "$content"');
      return content;
    } catch (e) {
      debugPrint('Summary error: $e');
      return '';
    }
  }

  /// Build context string from all cards in a session.
  String buildFullContext(List<TranscriptCard> cards) {
    final buf = StringBuffer();
    for (int i = 0; i < cards.length; i++) {
      final c = cards[i];
      buf.writeln(
        '--- ${c.timestamp}${c.title.isNotEmpty ? " (${c.title})" : ""} ---',
      );
      buf.writeln(c.text);
      if (c.partialText.isNotEmpty) buf.writeln(c.partialText);
      buf.writeln();
    }
    return buf.toString();
  }
}
