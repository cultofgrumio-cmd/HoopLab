import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:hooplab/models/session.dart';

class SessionStorage {
  static const _fileName = 'sessions.json';

  static Future<File> _getFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_fileName');
  }

  static Future<List<Session>> loadAll() async {
    try {
      final file = await _getFile();
      if (!file.existsSync()) return [];
      final json = jsonDecode(file.readAsStringSync()) as List<dynamic>;
      return json
          .map((s) => Session.fromJson(s as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> save(Session session) async {
    final sessions = await loadAll();
    final idx = sessions.indexWhere((s) => s.id == session.id);
    if (idx >= 0) {
      sessions[idx] = session;
    } else {
      sessions.insert(0, session);
    }
    final file = await _getFile();
    await file.writeAsString(
      jsonEncode(sessions.map((s) => s.toJson()).toList()),
    );
  }

  static Future<void> delete(String sessionId) async {
    final sessions = await loadAll();
    sessions.removeWhere((s) => s.id == sessionId);
    final file = await _getFile();
    await file.writeAsString(
      jsonEncode(sessions.map((s) => s.toJson()).toList()),
    );
  }
}
