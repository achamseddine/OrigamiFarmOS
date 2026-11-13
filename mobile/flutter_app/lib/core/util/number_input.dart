/// Parse quantities typed with Western, Arabic-Indic or Persian digits.
/// Reject ambiguous grouping and non-finite values; callers enforce domain bounds.
String? _normalise(String raw) {
  final input = raw.trim();
  if (input.isEmpty) return null;
  final out = StringBuffer();
  for (final rune in input.runes) {
    if (rune >= 0x0660 && rune <= 0x0669) {
      out.writeCharCode(0x30 + rune - 0x0660);
    } else if (rune >= 0x06F0 && rune <= 0x06F9) {
      out.writeCharCode(0x30 + rune - 0x06F0);
    } else if (rune == 0x066B || rune == 0x002C) {
      out.write('.');
    } else {
      out.writeCharCode(rune);
    }
  }
  return out.toString();
}

double? parseLocalizedDouble(String raw) {
  final value = _normalise(raw);
  if (value == null || !RegExp(r'^[+-]?[0-9]+(?:\.[0-9]+)?$').hasMatch(value)) return null;
  final parsed = double.tryParse(value);
  return parsed != null && parsed.isFinite ? parsed : null;
}

int? parseLocalizedInt(String raw) {
  final value = _normalise(raw);
  if (value == null || !RegExp(r'^[+-]?[0-9]+$').hasMatch(value)) return null;
  return int.tryParse(value);
}
