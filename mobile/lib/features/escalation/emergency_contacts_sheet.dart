import 'package:flutter/material.dart';

import '../../core/escalation/emergency_contact.dart';
import '../../core/escalation/escalation_service.dart';

/// Manages who gets an emergency SMS, and whether sends are real.
///
/// Contacts start empty on purpose: nothing can be transmitted until someone
/// deliberately enters a number.
class EmergencyContactsSheet extends StatefulWidget {
  const EmergencyContactsSheet({
    super.key,
    required this.escalation,
    required this.onChanged,
  });

  final EscalationService escalation;
  final Future<void> Function() onChanged;

  @override
  State<EmergencyContactsSheet> createState() => _EmergencyContactsSheetState();
}

class _EmergencyContactsSheetState extends State<EmergencyContactsSheet> {
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  String? _phoneError;

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final phone = _phoneController.text.trim();
    if (!EmergencyContact.isValidPhone(phone)) {
      setState(
        () => _phoneError = 'Enter 7–15 digits, optionally with +country code.',
      );
      return;
    }
    final name = _nameController.text.trim();
    widget.escalation.addContact(
      EmergencyContact(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        name: name.isEmpty ? 'Emergency contact' : name,
        phone: EmergencyContact.normalizePhone(phone),
      ),
    );
    await widget.onChanged();
    if (!mounted) return;
    setState(() {
      _phoneError = null;
      _nameController.clear();
      _phoneController.clear();
    });
  }

  Future<void> _remove(String id) async {
    widget.escalation.removeContact(id);
    await widget.onChanged();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final escalation = widget.escalation;
    final contacts = escalation.contacts;

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        child: SingleChildScrollView(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            bottom: MediaQuery.of(context).viewInsets.bottom + 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Emergency contacts',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 5),
              const Text(
                'Alerts are sent by SMS straight from this phone, so they work '
                'with no internet.',
                style: TextStyle(color: Color(0xFFB8CED5)),
              ),
              const SizedBox(height: 16),
              if (contacts.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 10),
                  child: Text(
                    'No contacts yet — nothing can be sent.',
                    style: TextStyle(color: Color(0xFFF6C859)),
                  ),
                ),
              ...contacts.map(
                (contact) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.person_outline),
                  title: Text(contact.name),
                  subtitle: Text(
                    contact.phone,
                    style: const TextStyle(color: Color(0xFF91AAB5)),
                  ),
                  trailing: IconButton(
                    tooltip: 'Remove ${contact.name}',
                    icon: const Icon(
                      Icons.delete_outline,
                      color: Color(0xFFFF7482),
                    ),
                    onPressed: () => _remove(contact.id),
                  ),
                ),
              ),
              const Divider(height: 24),
              TextField(
                controller: _nameController,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  hintText: 'Amma',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _phoneController,
                keyboardType: TextInputType.phone,
                decoration: InputDecoration(
                  labelText: 'Phone number',
                  hintText: '+91 90000 00001',
                  errorText: _phoneError,
                ),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  onPressed: _add,
                  icon: const Icon(Icons.add),
                  label: const Text('Add contact'),
                ),
              ),
              const Divider(height: 28),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: escalation.dryRun,
                onChanged: (value) => setState(() => escalation.dryRun = value),
                title: const Text('Rehearsal mode'),
                subtitle: const Text(
                  'Compose and report alerts without sending a real SMS. '
                  'Turn this off for a live demo.',
                  style: TextStyle(fontSize: 12, color: Color(0xFF91AAB5)),
                ),
              ),
              TextButton.icon(
                onPressed: () {
                  escalation.resetCooldowns();
                  setState(() {});
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Alert cooldowns cleared.')),
                  );
                },
                icon: const Icon(Icons.timer_off_outlined),
                label: const Text('Clear alert cooldowns'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
