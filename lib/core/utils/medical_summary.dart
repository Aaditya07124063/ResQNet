/// Medical details the user chose to save in their profile, appended to an
/// automatic SOS so responders see them. Empty fields are left out rather
/// than broadcast as blank labels.
String medicalSummary(String bloodGroup, String allergies) {
  final parts = <String>[
    if (bloodGroup.trim().isNotEmpty) 'Blood: ${bloodGroup.trim()}',
    if (allergies.trim().isNotEmpty) 'Allergies: ${allergies.trim()}',
  ];
  return parts.isEmpty ? '' : '\n${parts.join(' | ')}';
}
