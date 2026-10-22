/// Extracts fuel-token data from pasted 9771 SMS text (Urdu + English).
/// Pure static logic — no Flutter dependencies — so it is fully unit-testable.
///
/// Handles:
///  * Official Urdu format:
///    "آپ ٹوکن نمبر 8401712225 سے سواری نمبر NFF-2364 کے لیے 500 روپے کا فیول
///     ریلیف حاصل کر سکتے ہیں۔ یہ ٹوکن 16:47 25-Oct تک قابلِ استعمال ہے۔"
///  * English formats ("Token Number: 802014567", "Token: ABC-123", ...).
///  * Batch pastes: quoted blocks, double-newline paragraphs, and
///    one-message-per-line lists.
class SmsParser {
  static const Map<String, int> months = {
    'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6,
    'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12,
  };

  /// Marker that starts a token message — used to detect multi-message chunks.
  static final RegExp _marker = RegExp(r'ٹوکن\s*نمبر|[Tt]oken\b');

  /// WhatsApp/export header e.g. "[17/10, 10:08 pm] Jawad: " — date and
  /// clock may appear in EITHER order, 12h or 24h, with or without am/pm;
  /// also matches unbracketed copies like "17/10, 10:08 pm - Name:".
  /// Including doubled headers from nested forwards: the second header is
  /// matched in the same global pass and removed too. The trailing
  /// "…Name:" part accepts ANY sender name (Arabic script included).
  static final RegExp _headerPrefix = RegExp(
    r'\[\s*'
    r'(?:\d{1,2}[/-]\d{1,2}(?:[/-]\d{2,4})?\s*,?\s*\d{1,2}:\d{2}(?::\d{2})?'
    r'|\d{1,2}:\d{2}(?::\d{2})?\s*,?\s*\d{1,2}[/-]\d{1,2}(?:[/-]\d{2,4})?)'
    r'(?:\s*[APap]\.?[Mm]\.?)?\s*\]'
    r'\s*[^:\n]{0,60}:\s*'
    r'|\d{1,2}[/-]\d{1,2}(?:[/-]\d{2,4})?\s*,?\s*\d{1,2}:\d{2}(?::\d{2})?'
    r'(?:\s*[APap]\.?[Mm]\.?)?\s*[-–~>]\s*[^:\n>]{0,60}\s*:\s*',
    caseSensitive: false,
  );

  /// Bidirectional/markup noise that WhatsApp forwards inject:
  /// ‎ — isolation marks between the time digits and the rest of the line
  /// would break the "16:47 25-Oct" matcher if left in place.
  static final RegExp _dirMarks = RegExp('[\u200E\u200F\u202A-\u202E\u2066-\u2069]');

  /// Any anchor that starts a token message in EITHER language. Windows are
  /// cut between consecutive anchors, so one message's fields can never be
  /// read from inside another message's window. Case-insensitive: forwards
  /// freely mix "Token Number" / "TOKEN NO" / "token number".
  static final RegExp _tokenAnchor = RegExp(
    r'ٹوکن\s*نمبر|[Tt]oken\s*(?:number|no\.?|num)|\bTOK\b',
    caseSensitive: false,
  );

  /// Pre-parse cleanup for messy forwarded pastes (nested forwards, RTL
  /// marks, stray markup).
  static String _normalize(String text) => text
      .replaceAll(_dirMarks, '')
      .replaceAll(_headerPrefix, '') // strip "[17/10, 10:08 pm] Jawad: " etc.
      .replaceAll('*', '') // WhatsApp bold markers
      .replaceAll('`', '')
      .trim();

  // ── Date/time parsing ─────────────────────────────────────────────────────

  /// Parses "16:47" + "25-Oct" into a DateTime in the current year.
  /// Handles Dec→Jan rollover. Returns null for unknown months or
  /// impossible day-of-month values instead of silently guessing.
  static DateTime? parseExpiry(String timeStr, String dateStr) {
    try {
      final timeParts = timeStr.trim().split(':');
      final hour = int.parse(timeParts[0].trim());
      final minute = int.parse(timeParts[1].trim());
      if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;

      final dateParts = dateStr.trim().split('-');
      final day = int.parse(dateParts[0].trim());
      final month = months[dateParts[1].trim().toLowerCase()];
      if (month == null) return null;
      if (day < 1 || day > 31) return null;

      final now = DateTime.now();
      int year = now.year;
      // Expiry written without a year: if we're in December and the expiry
      // month is January, it must belong to next year.
      if (now.month == 12 && month == 1) year += 1;

      final daysInMonth = DateTime(year, month + 1, 0).day;
      if (day > daysInMonth) return null; // e.g. "31-Feb" → reject, don't roll

      return DateTime(year, month, day, hour, minute);
    } catch (_) {
      return null;
    }
  }

  // ── Message extraction ────────────────────────────────────────────────────

  static List<ExtractedSmsToken> parse(String text) {
    final results = <ExtractedSmsToken>[];
    final cleaned = _normalize(text);
    if (cleaned.isEmpty) return results;

    // ── Token-marker windowing (the mixing-proof path) ────────────────────
    // Every field a message owns lies between ITS token marker and the NEXT
    // message's token marker. Cutting windows there means a blank/failed
    // read can never reach into the neighbour message's digits — plates,
    // amounts and times are harvested strictly inside their own window.
    final anchors = _tokenAnchor.allMatches(cleaned).toList();
    if (anchors.length >= 2) {
      for (int i = 0; i < anchors.length; i++) {
        final start = anchors[i].start;
        final end = i + 1 < anchors.length ? anchors[i + 1].start : cleaned.length;
        _parseWindow(cleaned.substring(start, end), results);
      }
    } else if (anchors.length == 1) {
      // Single message — parse from its marker to the end of the text.
      final window = cleaned.substring(anchors.first.start);
      _parseWindow(window, results);
    } else {
      // No token marker anywhere: keep the legacy chunking for odd formats
      // (quote blocks, paragraph batches) and per-line fallbacks.
      final rawChunks = <String>[];
      final quoted = RegExp(r'["“]([^"”]+)["”]').allMatches(cleaned);
      if (quoted.isNotEmpty) {
        for (final m in quoted) {
          final content = m.group(1)?.trim();
          if (content != null && content.isNotEmpty) rawChunks.add(content);
        }
      } else {
        rawChunks.addAll(cleaned.split(RegExp(r'\n{2,}|---+|={3,}')));
      }

      final chunks = <String>[];
      for (final paragraph in rawChunks) {
        final markers = _marker.allMatches(paragraph).length;
        if (markers >= 2 && paragraph.contains('\n')) {
          chunks.addAll(paragraph.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty));
        } else {
          final trimmed = paragraph.trim();
          if (trimmed.isNotEmpty) chunks.add(trimmed);
        }
      }
      for (final msg in chunks) {
        _parseWindow(msg, results);
      }
    }

    _markBatchDuplicates(results);
    return results;
  }

  /// Marks repeated appearances of the same token code INSIDE one input
  /// (forwarded batches repeat tokens constantly). First occurrence stays
  /// active; later copies are auto-skipped with a "duplicate" flag so the
  /// user sees they were intentionally collapsed, and can un-skip if they
  /// disagree. Cross-run duplicates are still guarded at save time by the
  /// DB (tokenCodeExists — catches already-added AND already-used tokens).
  static void _markBatchDuplicates(List<ExtractedSmsToken> results) {
    final seen = <String>{};
    for (final e in results) {
      final code = e.tokenCode.trim().toUpperCase();
      if (code.isEmpty) continue;
      if (seen.contains(code)) {
        e
          ..dupInBatch = true
          ..skip = true;
      } else {
        seen.add(code);
      }
    }
  }

  static void _parseWindow(String msg, List<ExtractedSmsToken> results) {
    if (msg.trim().isEmpty) return;
    msg = msg.trim();

    String? tokenCode;
    String? vehicleNo;
    double? reliefAmount;
    DateTime? expiryDate;
    String? expiryText;
    String? typeHint;

    // Vehicle type is NOT encoded in Pakistani plates (letter series =
    // issuing city, same numbering for cars & bikes), so detect it from the
    // message wording when the SMS explicitly names it. Null = leave default.
    if (RegExp(
      r'motor\s?cycle|motorcycle|\bbike\b|two.?wheeler|موٹر\s?سائیکل|سائیکل',
      caseSensitive: false,
    ).hasMatch(msg)) {
      typeHint = 'motorcycle';
    } else if (RegExp(
      r'rickshaw|ricksha|رکشہ',
      caseSensitive: false,
    ).hasMatch(msg)) {
      typeHint = 'rickshaw';
    } else if (RegExp(
      r'qingqi|qingchi|چنگچی',
      caseSensitive: false,
    ).hasMatch(msg)) {
      typeHint = 'qingqi';
    } else if (RegExp(r'\bcar\b|car', caseSensitive: false).hasMatch(msg)) {
      typeHint = 'smallCar';
    }

    // ── Urdu matchers ────────────────────────────────────────────────────
    final urduToken = RegExp(r'ٹوکن\s*نمبر\s*([0-9A-Za-z\-]+)').firstMatch(msg);
    if (urduToken != null) {
      tokenCode = urduToken.group(1)?.trim().toUpperCase();
    }

    final urduVehicle = RegExp(r'سواری\s*نمبر\s*([A-Za-z0-9\-]+)').firstMatch(msg);
    if (urduVehicle != null) {
      final v = urduVehicle.group(1)?.trim().toUpperCase() ?? '';
      if (v.isNotEmpty && v != tokenCode) vehicleNo = v;
    }

    final urduAmount = RegExp(r'(\d+)\s*روپے').firstMatch(msg);
    if (urduAmount != null) {
      reliefAmount = double.tryParse(urduAmount.group(1) ?? '');
    }

    final urduExpiry = RegExp(
      r'یہ ٹوکن\s*([0-9]{1,2}:[0-9]{2})\s*([0-9]{1,2}-[A-Za-z]{3})',
    ).firstMatch(msg);
    if (urduExpiry != null) {
      expiryText = '${urduExpiry.group(2)}, ${urduExpiry.group(1)}';
      expiryDate = parseExpiry(urduExpiry.group(1)!, urduExpiry.group(2)!);
    }

    // ── English fallback matchers ────────────────────────────────────────
    if (tokenCode == null) {
      final enTokenPatterns = [
        // "Token Number: 820014567" / "Token No 820014567" — must consume
        // the optional word NUMBER before capturing, else we'd capture the
        // word "NUMBER" itself.
        RegExp(r'token\s*(?:number|no\.?|num)\s*[:\-#]*\s*([A-Z0-9][A-Z0-9\-]{3,18})', caseSensitive: false),
        RegExp(r'token\s*[:\-#]+\s*([A-Z0-9][A-Z0-9\-]{3,18})', caseSensitive: false),
        RegExp(r'\bcode\s*[:\-#]+\s*([A-Z0-9][A-Z0-9\-]{3,18})', caseSensitive: false),
        RegExp(r'\bTOK\s*[:\-#]+\s*([A-Z0-9][A-Z0-9\-]{3,18})', caseSensitive: false),
      ];
      for (final p in enTokenPatterns) {
        final m = p.firstMatch(msg);
        final candidate = m?.group(1)?.trim().toUpperCase();
        if (candidate != null && candidate.contains(RegExp(r'\d'))) {
          tokenCode = candidate;
          break;
        }
      }
    }

    if (vehicleNo == null) {
      final enVehiclePatterns = [
        RegExp(r'vehicle\s*(?:no\.?|number)?\s*[:\-]+\s*([A-Z0-9\-]{3,10})', caseSensitive: false),
        RegExp(r'plate\s*[:\-]+\s*([A-Z0-9\-]{3,10})', caseSensitive: false),
        RegExp(r'reg(?:istration)?\s*[:\-]+\s*([A-Z0-9\-]{3,10})', caseSensitive: false),
        // Generic plate fallback: "Lea-4567" / "LEA 4567" — digits required
        // so bare month words never match.
        RegExp(r'\b([A-Z]{2,4}[-\s]?\d{2,5})\b', caseSensitive: false),
      ];
      for (final p in enVehiclePatterns) {
        final m = p.firstMatch(msg);
        final v = m?.group(1)?.trim().toUpperCase().replaceAll(' ', '-') ?? '';
        if (v.isNotEmpty && v != tokenCode) {
          vehicleNo = v;
          break;
        }
      }
    }

    if (reliefAmount == null) {
      final enAmt =
          RegExp(r'Rs\.?\s*(\d+)|(\d+)\s*rupees', caseSensitive: false).firstMatch(msg);
      if (enAmt != null) {
        reliefAmount = double.tryParse(enAmt.group(1) ?? enAmt.group(2) ?? '');
      }
    }

    // ── RESCUE pass — incomplete / forwarded fragments ───────────────────
    // Official 9771 text always labels the token ("ٹوکن نمبر …"), but
    // fragile forwards often lose part of the sentence, e.g.
    //   "نمبر 5271049386 سے سواری نمبر NFC-7043"
    // The token itself is always a clean 9–10 digit run and the plate is
    // letters + 3–4 digits with a dash or space — so recognise those
    // SHAPES without the missing label: first a "نمبر <digits>" pair
    // (digits only — the plate's نمبر is followed by letters, never this),
    // then any standalone 9–10 digit run. Look-arounds keep the bare
    // fallback away from longer digit runs (CNIC-style 13-digit numbers).
    if (tokenCode == null) {
      final labeled = RegExp(r'نمبر\s*(\d{9,10})\b').firstMatch(msg);
      tokenCode = labeled?.group(1) ??
          RegExp(r'(?<!\d)(\d{9,10})(?!\d)').firstMatch(msg)?.group(1);
    }

    if (expiryDate == null) {
      // Generic fallback anywhere in the message: "16:47 25-Oct"
      final genExpiry = RegExp(r'([0-9]{1,2}:[0-9]{2})\s+([0-9]{1,2}-[A-Za-z]{3})').firstMatch(msg);
      if (genExpiry != null) {
        expiryText = '${genExpiry.group(2)}, ${genExpiry.group(1)}';
        expiryDate = parseExpiry(genExpiry.group(1)!, genExpiry.group(2)!);
      }
    }

    if (tokenCode != null || vehicleNo != null) {
      results.add(ExtractedSmsToken(
        rawMessage: msg,
        tokenCode: tokenCode ?? '',
        vehicleNo: vehicleNo ?? '',
        reliefAmount: reliefAmount,
        expiryDate: expiryDate,
        expiryDisplay: expiryText,
        vehicleTypeHint: typeHint,
      ));
    } else if (msg.length > 8) {
      results.add(ExtractedSmsToken(
        rawMessage: msg,
        tokenCode: '',
        vehicleNo: '',
        expiryDisplay: '',
        unrecognised: true,
      ));
    }
  }
}

/// One message extracted from the pasted SMS text.
class ExtractedSmsToken {
  final String rawMessage;
  String tokenCode;
  String vehicleNo;
  double? reliefAmount;
  DateTime? expiryDate;
  String? expiryDisplay;
  String? vehicleTypeHint; // from SMS wording; null when not stated
  bool unrecognised;
  bool skip;
  /// True when the same token code appeared earlier in the SAME input
  /// (forwarded batches). Auto-skipped; user can re-include manually.
  bool dupInBatch;

  ExtractedSmsToken({
    required this.rawMessage,
    required this.tokenCode,
    required this.vehicleNo,
    this.reliefAmount,
    this.expiryDate,
    this.expiryDisplay,
    this.vehicleTypeHint,
    this.unrecognised = false,
    this.skip = false,
    this.dupInBatch = false,
  });
}
