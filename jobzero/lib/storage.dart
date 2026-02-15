import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'models.dart';

class StorageService {
  static const _dir = 'jobzero_sessions';

  Future<Directory> get _sessionDir async {
    final appDir = await getApplicationSupportDirectory();
    final dir = Directory('${appDir.path}/$_dir');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<void> saveSession(Session session) async {
    final dir = await _sessionDir;
    final file = File('${dir.path}/${session.id}.json');
    await file.writeAsString(jsonEncode(session.toJson()));
  }

  Future<Session?> loadSession(String id) async {
    final dir = await _sessionDir;
    final file = File('${dir.path}/$id.json');
    if (!await file.exists()) return null;
    final content = await file.readAsString();
    final json = jsonDecode(content) as Map<String, dynamic>;
    return Session.fromJson(json);
  }

  Future<List<SessionMeta>> listSessions() async {
    final dir = await _sessionDir;
    if (!await dir.exists()) return [];

    final entities = await dir.list().toList();
    final files = entities.whereType<File>().where(
      (f) => f.path.endsWith('.json'),
    );
    final metas = <SessionMeta>[];

    for (final file in files) {
      try {
        final json =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        metas.add(
          SessionMeta(
            id: json['id'] as String,
            name: json['name'] as String? ?? '',
            createdAt: DateTime.parse(json['createdAt'] as String),
            cardCount: (json['cards'] as List?)?.length ?? 0,
          ),
        );
      } catch (_) {}
    }

    metas.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return metas;
  }

  Future<void> deleteSession(String id) async {
    final dir = await _sessionDir;
    final file = File('${dir.path}/$id.json');
    if (await file.exists()) await file.delete();
  }

  Future<void> saveLastSessionId(String id) async {
    final dir = await _sessionDir;
    final file = File('${dir.path}/_last.txt');
    await file.writeAsString(id);
  }

  Future<String?> getLastSessionId() async {
    final dir = await _sessionDir;
    final file = File('${dir.path}/_last.txt');
    if (!await file.exists()) return null;
    return (await file.readAsString()).trim();
  }
}
