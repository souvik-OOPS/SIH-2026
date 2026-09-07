import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:sqflite/sqflite.dart';

import '../models/assistant_context.dart';

/// One bundled reference entry. The assistant may quote these; it may not contradict
/// them, and with no LLM the best match is returned verbatim.
class KnowledgeEntry {
  const KnowledgeEntry({
    required this.id,
    required this.title,
    required this.keywords,
    required this.question,
    required this.answer,
    required this.category,
    required this.language,
    this.sourceTitle,
    this.sourceUrl,
    this.reviewedAt,
  });

  final String id;
  final String title;
  final String keywords;
  final String question;
  final String answer;
  final String category;
  final String language;
  final String? sourceTitle;
  final String? sourceUrl;
  final String? reviewedAt;

  static KnowledgeEntry? fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final answer = json['answer'];
    if (id is! String || id.isEmpty || answer is! String || answer.isEmpty) {
      return null;
    }
    final keywords = json['keywords'];
    return KnowledgeEntry(
      id: id,
      title: json['title'] as String? ?? id,
      keywords: keywords is List
          ? keywords.whereType<String>().join(' ')
          : (keywords as String? ?? ''),
      question: json['question'] as String? ?? '',
      answer: answer,
      category: json['category'] as String? ?? 'general',
      language: json['language'] as String? ?? 'en',
      sourceTitle: json['sourceTitle'] as String?,
      sourceUrl: json['sourceUrl'] as String?,
      reviewedAt: json['reviewedAt'] as String?,
    );
  }

  String toPromptSnippet() => '- ${title.toUpperCase()}: $answer';
}

typedef KnowledgeLoader = Future<String> Function(String assetPath);
typedef DatabaseOpener = Future<Database> Function();

/// Offline corpus with deterministic full-corpus ranking. SQLite maintains a
/// searchable copy with the available FTS module, but platform-specific FTS
/// ordering never decides the returned answer. Retrieval also works if SQLite
/// is unavailable, as long as the bundled JSON loaded successfully.
class LocalKnowledgeService {
  LocalKnowledgeService({
    KnowledgeLoader? loader,
    DatabaseOpener? opener,
    String? assetPath,
  }) : _loader = loader ?? rootBundle.loadString,
       _opener = opener ?? (() => openDatabase(inMemoryDatabasePath)),
       _assetPath = assetPath ?? 'assets/knowledge/assistant_knowledge.json';

  final KnowledgeLoader _loader;
  final DatabaseOpener _opener;
  final String _assetPath;

  Database? _db;
  bool _ftsAvailable = true;
  String? _ftsModule;
  bool _loaded = false;
  int _entryCount = 0;
  List<KnowledgeEntry> _entries = const [];

  bool get isLoaded => _loaded;
  int get entryCount => _entryCount;
  bool get usesFts => _ftsAvailable;

  /// Available SQLite module: `fts5`, `fts4`, or null for a plain table.
  String? get ftsModule => _ftsModule;

  /// Never throws: a missing or corrupt corpus degrades to "no knowledge",
  /// which the assistant reports honestly rather than crashing on.
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final entries = await _readCorpus();
      if (entries.isEmpty) return;
      _entries = entries;
      _entryCount = entries.length;

      final db = await _opener();
      _db = db;
      await _createSchema(db);

      final batch = db.batch();
      for (final entry in entries) {
        final row = {
          'id': entry.id,
          'title': entry.title,
          'keywords': entry.keywords,
          'question': entry.question,
          'answer': entry.answer,
          'category': entry.category,
          'language': entry.language,
        };
        // A virtual table rejects INSERT OR REPLACE, so only the plain-table
        // fallback gets a conflict algorithm.
        if (_ftsAvailable) {
          batch.insert('knowledge', row);
        } else {
          batch.insert(
            'knowledge',
            row,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      }
      await batch.commit(noResult: true);
      _entryCount = entries.length;
    } on Object catch (error) {
      debugPrint('[assistant] knowledge load failed: $error');
    }
  }

  Future<List<KnowledgeEntry>> _readCorpus() async {
    try {
      final decoded = jsonDecode(await _loader(_assetPath));
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map(
            (entry) =>
                KnowledgeEntry.fromJson(Map<String, dynamic>.from(entry)),
          )
          .whereType<KnowledgeEntry>()
          .toList();
    } on Object {
      return const [];
    }
  }

  Future<void> _createSchema(Database db) async {
    const columns = 'id, title, keywords, question, answer, category, language';
    for (final module in ['fts5', 'fts4']) {
      try {
        await db.execute(
          'CREATE VIRTUAL TABLE IF NOT EXISTS knowledge USING $module($columns)',
        );
        _ftsAvailable = true;
        _ftsModule = module;
        return;
      } on Object {
        // This build lacks the module; try the next one.
      }
    }
    debugPrint('[assistant] no FTS module available, using a plain table');
    _ftsAvailable = false;
    _ftsModule = null;
    await db.execute(
      'CREATE TABLE IF NOT EXISTS knowledge('
      'id TEXT PRIMARY KEY, title TEXT, keywords TEXT, question TEXT, '
      'answer TEXT, category TEXT, language TEXT)',
    );
  }

  /// Top [limit] entries for [query], best first, restricted to [language].
  ///
  /// Returns empty rather than an irrelevant entry — callers must handle
  /// "no match" instead of being handed something unrelated.
  Future<List<KnowledgeEntry>> search(
    String query, {
    int limit = 3,
    AssistantLanguage language = AssistantLanguage.english,
  }) async {
    // Score the small bundled corpus identically on FTS4, FTS5, and phones
    // without FTS. SQL LIMIT must never discard the best match before ranking.
    if (_entries.isEmpty || limit <= 0) return const [];
    final terms = _terms(query);
    if (terms.isEmpty) return const [];
    String normalized(String value) => _split(value, const {}).join(' ');
    final scored = <({KnowledgeEntry entry, double score})>[];
    for (final entry in _entries.where((e) => e.language == language.code)) {
      final exact = normalized(entry.question) == normalized(query);
      final keywords = _terms('${entry.title} ${entry.keywords}').toSet();
      final question = _terms(entry.question).toSet();
      final hits = terms
          .where((t) => keywords.contains(t) || question.contains(t))
          .length;
      if (!exact && (hits == 0 || hits / terms.length < 0.5)) continue;
      final score = exact
          ? 1000.0
          : terms.fold<double>(
                  0,
                  (sum, term) =>
                      sum +
                      (keywords.contains(term) ? 4 : 0) +
                      (question.contains(term) ? 2 : 0),
                ) /
                terms.length;
      scored.add((entry: entry, score: score));
    }
    scored.sort((a, b) {
      final order = b.score.compareTo(a.score);
      return order == 0 ? a.entry.id.compareTo(b.entry.id) : order;
    });
    return scored.take(limit).map((r) => r.entry).toList();
  }

  /// Generic question verbs are dropped: without this, "Explain my current
  /// condition" matches every entry whose question starts with "Explain".
  static const _stopWords = {
    'a',
    'an',
    'and',
    'are',
    'as',
    'at',
    'be',
    'but',
    'by',
    'do',
    'does',
    'for',
    'from',
    'has',
    'have',
    'how',
    'i',
    'in',
    'is',
    'it',
    'its',
    'me',
    'my',
    'of',
    'on',
    'or',
    'that',
    'the',
    'this',
    'to',
    'was',
    'what',
    'when',
    'why',
    'with',
    'you',
    'your',
    'explain',
    'mean',
    'means',
    'tell',
    'show',
    'about',
    'can',
    'am',
    'getting',
  };

  /// Articles only. Used when the full filter strips a question to nothing,
  /// which happens with short generic phrasings like "What should I do now?"
  static const _minimalStopWords = {'a', 'an', 'the', 'is', 'it', 'my', 'to'};

  static List<String> _terms(String value) {
    final full = _split(value, _stopWords);
    // A question made entirely of common words still deserves an answer, so
    // retry with only articles removed rather than returning nothing.
    return full.isNotEmpty ? full : _split(value, _minimalStopWords);
  }

  static List<String> _split(String value, Set<String> stopWords) => value
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9ऀ-ॿ]+'))
      .where((token) => token.length > 1 && !stopWords.contains(token))
      .toSet()
      .toList();

  Future<void> dispose() async {
    await _db?.close();
    _db = null;
  }
}
