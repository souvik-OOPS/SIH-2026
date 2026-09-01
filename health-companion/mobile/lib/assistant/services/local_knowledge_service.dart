import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

/// One curated entry. The assistant may quote these; it may not contradict
/// them, and when no LLM is available the top entry is returned verbatim.
class KnowledgeEntry {
  const KnowledgeEntry({
    required this.id,
    required this.title,
    required this.keywords,
    required this.question,
    required this.answer,
    required this.category,
  });

  final String id;
  final String title;
  final List<String> keywords;
  final String question;
  final String answer;
  final String category;

  static KnowledgeEntry? fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final answer = json['answer'];
    if (id is! String || id.isEmpty || answer is! String || answer.isEmpty) {
      return null;
    }
    return KnowledgeEntry(
      id: id,
      title: json['title'] as String? ?? id,
      keywords:
          (json['keywords'] as List?)?.whereType<String>().toList() ?? const [],
      question: json['question'] as String? ?? '',
      answer: answer,
      category: json['category'] as String? ?? 'general',
    );
  }

  String toPromptSnippet() => '- ${title.toUpperCase()}: $answer';
}

typedef KnowledgeLoader = Future<String> Function(String assetPath);

/// Lightweight offline retrieval over a bundled corpus.
///
/// Pure Dart keyword scoring rather than SQLite FTS: the corpus is a few
/// dozen entries, this adds no native dependency and no extra build surface,
/// and it is trivially unit-testable. If the corpus ever grows past a few
/// hundred entries, swap the scorer for FTS behind this same interface.
class LocalKnowledgeService {
  LocalKnowledgeService({KnowledgeLoader? loader, String? assetPath})
    : _loader = loader ?? rootBundle.loadString,
      _assetPath = assetPath ?? 'assets/knowledge/assistant_knowledge.json';

  final KnowledgeLoader _loader;
  final String _assetPath;

  List<KnowledgeEntry> _entries = const [];
  bool _loaded = false;

  bool get isLoaded => _loaded;
  int get entryCount => _entries.length;

  /// Never throws: a missing or corrupt corpus degrades to "no knowledge",
  /// which the assistant reports honestly rather than crashing on.
  Future<void> load() async {
    if (_loaded) return;
    try {
      final decoded = jsonDecode(await _loader(_assetPath));
      if (decoded is! List) {
        _entries = const [];
      } else {
        _entries = decoded
            .whereType<Map>()
            .map(
              (entry) =>
                  KnowledgeEntry.fromJson(Map<String, dynamic>.from(entry)),
            )
            .whereType<KnowledgeEntry>()
            .toList();
      }
    } on Object {
      _entries = const [];
    }
    _loaded = true;
  }

  /// Top [limit] entries by keyword overlap, best first. Empty when nothing
  /// scores above zero — callers must handle "no match" rather than being
  /// handed an irrelevant entry.
  List<KnowledgeEntry> search(String query, {int limit = 3}) {
    if (_entries.isEmpty) return const [];
    final tokens = _tokenize(query);
    if (tokens.isEmpty) return const [];

    final scored = <({KnowledgeEntry entry, int score})>[];
    for (final entry in _entries) {
      final score = _score(entry, tokens, query.toLowerCase());
      if (score > 0) scored.add((entry: entry, score: score));
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.take(limit).map((e) => e.entry).toList();
  }

  static int _score(KnowledgeEntry entry, Set<String> tokens, String raw) {
    var score = 0;
    for (final keyword in entry.keywords) {
      final lower = keyword.toLowerCase();
      // A multi-word keyword only counts as a phrase hit, which keeps
      // "no finger" from matching every question containing "no".
      if (lower.contains(' ')) {
        if (raw.contains(lower)) score += 5;
        continue;
      }
      if (tokens.contains(lower)) score += 3;
    }
    for (final token in _tokenize(entry.title)) {
      if (tokens.contains(token)) score += 2;
    }
    for (final token in _tokenize(entry.question)) {
      if (tokens.contains(token)) score += 1;
    }
    return score;
  }

  static final _stopWords = {
    'a', 'an', 'and', 'are', 'as', 'at', 'be', 'but', 'by', 'do', 'does',
    'for', 'from', 'has', 'have', 'how', 'i', 'in', 'is', 'it', 'its', 'me',
    'my', 'of', 'on', 'or', 'that', 'the', 'this', 'to', 'was', 'what',
    'when', 'why', 'with', 'you', 'your',
    // Generic question verbs. Without these, "Explain my current readings"
    // scores against every entry whose question starts with "Explain".
    'explain', 'mean', 'means', 'tell', 'show', 'about', 'can', 'should',
  };

  static Set<String> _tokenize(String value) => value
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9]+'))
      .where((token) => token.length > 1 && !_stopWords.contains(token))
      .toSet();
}
