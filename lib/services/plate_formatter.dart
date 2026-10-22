import 'package:flutter/services.dart';

/// Formats Pakistani vehicle plates as the user types:
///  * forces uppercase,
///  * strips invalid characters,
///  * auto-inserts the dash where the letter series ends and the digits start
///    (e.g. "NFF" + "2364" → "NFF-2364", "LEA4567A" → "LEA-4567-A" style tails
///    without a dash between digit and trailing letter).
///
/// Note: Flutter cannot switch the soft keyboard layout mid-field, so the
/// keyboard stays alphanumeric; the formatter guarantees the FORMAT just like
/// a numeric keypad would for digits.
class PlateInputFormatter extends TextInputFormatter {
  static const _maxLength = 12; // room for e.g. "AA-BB-1234" style tails

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    var text = newValue.text.toUpperCase();

    // Keep only letters, digits and dashes; collapse multiple dashes.
    text = text.replaceAll(RegExp(r'[^A-Z0-9\-]'), '')
        .replaceAll(RegExp(r'-{2,}'), '-');

    // Auto-dash: insert between a letter run and the first digit.
    final letters = RegExp(r'^[A-Z]+');
    final m = letters.firstMatch(text);
    if (m != null && m.end < text.length) {
      final rest = text.substring(m.end);
      if (!rest.startsWith('-')) {
        text = '${text.substring(0, m.end)}-$rest';
      }
    }

    if (text.length > _maxLength) {
      text = text.substring(0, _maxLength);
    }

    // Preserve caret at the end (plates are short; end-cursor is predictable).
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}
