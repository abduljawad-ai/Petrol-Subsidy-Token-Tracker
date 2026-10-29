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

/// Formats a CNIC as `#####-#######-#` while typing and keeps the caret
/// next to the digit the user just typed/removed.
class CnicInputFormatter extends TextInputFormatter {
  static const _maxDigits = 13;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final raw = newValue.text;
    final cursor = newValue.selection.baseOffset;
    final upTo = cursor < 0
        ? ''
        : raw.substring(0, cursor.clamp(0, raw.length));
    final digitsBefore = upTo.replaceAll(RegExp(r'[^0-9]'), '').length;

    var digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length > _maxDigits) digits = digits.substring(0, _maxDigits);

    final text = _format(digits);
    // Place the caret after the same number of digits it was after before.
    var offset = 0;
    var seen = 0;
    if (digitsBefore > 0) {
      offset = text.length;
      for (var i = 0; i < text.length; i++) {
        if (_isDigit(text[i])) {
          seen++;
          if (seen == digitsBefore) {
            offset = i + 1;
            break;
          }
        }
      }
    }
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: offset),
    );
  }

  static bool _isDigit(String ch) {
    final c = ch.codeUnitAt(0);
    return c >= 48 && c <= 57;
  }

  static String _format(String digits) {
    final b = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i == 5 || i == 12) b.write('-');
      b.write(digits[i]);
    }
    return b.toString();
  }
}
