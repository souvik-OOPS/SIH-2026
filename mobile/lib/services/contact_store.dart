import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../core/escalation/emergency_contact.dart';

/// Local persistence for emergency contacts.
///
/// Deliberately on-device only: these are phone numbers of the wearer's
/// family, and this project's whole premise is that it keeps working with no
/// server involved.
class ContactStore {
  static const _key = 'emergency_contacts_v1';

  Future<List<EmergencyContact>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null || raw.isEmpty) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map(
            (entry) =>
                EmergencyContact.fromJson(Map<String, dynamic>.from(entry)),
          )
          .whereType<EmergencyContact>()
          .toList();
    } on Object {
      // Corrupt storage must not stop the app from monitoring.
      return const [];
    }
  }

  Future<void> save(List<EmergencyContact> contacts) async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(
      contacts.map((contact) => contact.toJson()).toList(),
    );
    await prefs.setString(_key, encoded);
  }
}
