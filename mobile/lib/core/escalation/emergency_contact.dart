/// Someone the wearer nominated to be told when a critical event fires.
class EmergencyContact {
  const EmergencyContact({
    required this.id,
    required this.name,
    required this.phone,
  });

  final String id;
  final String name;
  final String phone;

  /// Digits plus an optional leading `+`. Deliberately permissive about
  /// spacing and dashes so a pasted number is not rejected on formatting.
  static bool isValidPhone(String value) {
    final trimmed = value.replaceAll(RegExp(r'[\s\-()]'), '');
    return RegExp(r'^\+?\d{7,15}$').hasMatch(trimmed);
  }

  static String normalizePhone(String value) =>
      value.replaceAll(RegExp(r'[\s\-()]'), '');

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'phone': phone};

  static EmergencyContact? fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final name = json['name'];
    final phone = json['phone'];
    if (id is! String || name is! String || phone is! String) return null;
    if (id.isEmpty || phone.isEmpty) return null;
    return EmergencyContact(id: id, name: name, phone: phone);
  }

  @override
  bool operator ==(Object other) =>
      other is EmergencyContact &&
      other.id == id &&
      other.name == name &&
      other.phone == phone;

  @override
  int get hashCode => Object.hash(id, name, phone);
}
