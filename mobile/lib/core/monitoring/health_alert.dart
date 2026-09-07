class HealthAlert {
  const HealthAlert({
    required this.id,
    required this.type,
    required this.title,
    required this.body,
    required this.at,
    required this.critical,
    this.demo = false,
    this.acknowledged = false,
  });
  final String id, type, title, body;
  final DateTime at;
  final bool critical, demo, acknowledged;
  Map<String, Object?> toRow() => {
    'id': id,
    'type': type,
    'title': title,
    'body': body,
    'at': at.millisecondsSinceEpoch,
    'critical': critical ? 1 : 0,
    'demo': demo ? 1 : 0,
    'acknowledged': acknowledged ? 1 : 0,
  };
  factory HealthAlert.fromRow(Map<String, Object?> row) => HealthAlert(
    id: row['id'] as String,
    type: row['type'] as String,
    title: row['title'] as String,
    body: row['body'] as String,
    at: DateTime.fromMillisecondsSinceEpoch(row['at'] as int),
    critical: row['critical'] == 1,
    demo: row['demo'] == 1,
    acknowledged: row['acknowledged'] == 1,
  );
}
