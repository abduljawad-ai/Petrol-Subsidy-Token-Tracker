// OCR photo reader — Google Gemini (free API key, pasted by the user in
// Settings). The key is NEVER compiled into the app: it lives only in this
// phone's database meta table so everyone can use their own key.
//
/// Architecture (decided by benchmark + user):
///  * BULK pick, SEPARATE processing: the user selects many photos at once,
///    but every photo is ONE Gemini request with its own response. A bad
///    photo can never contaminate another photo's digits.
///  * Model `gemini-3.5-flash-lite` scored 4/4 PERFECT on the four real
///    keypad-phone photos in `images to test ocr/` (see RESEARCH_OCR.md);
///    OCR.space and DeepRead failed that test and are not used.
///  * Each returned token becomes a pseudo-SMS line and runs through the
///    SAME SmsParser as pasted text — one extraction codebase, one
///    validation path, one review flow.
library;
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import '../db/database_helper.dart';
import 'sms_parser.dart';

const String kOcrModel = 'gemini-3.5-flash-lite';
// Fallbacks in a DIFFERENT capacity pool: the big flash model answered 503
// after 52 s in our timing test — that waiting was the cause of a 2-minute
// batch on the phone. Chain: lite -> 3.1-lite; a final failure shows a
// retry button instead of hanging.
const String kOcrFallbackModel = 'gemini-3.1-flash-lite';
const String kOcrKeyMeta = 'gemini_api_key';

/// One token extracted from one photo.
class OcrItem {
  final ExtractedSmsToken parsed;
  final double confidence;
  final String sourceImage;

  OcrItem({required this.parsed, required this.confidence, required this.sourceImage});

  /// Below 0.9 model confidence, a token that is not exactly 10 digits, or
  /// a missing plate gets flagged amber — the user decides, nothing saves
  /// silently wrong.
  bool get needsCheck =>
      confidence < 0.9 || parsed.tokenCode.length != 10 || parsed.vehicleNo.isEmpty;
}

/// Result of reading ONE photo.
class OcrImageResult {
  final String imagePath;
  final bool ok;
  final String? error;
  final List<OcrItem> items;

  OcrImageResult({required this.imagePath, required this.ok, this.error, this.items = const []});
}

class _OcrError implements Exception {
  final String message;
  _OcrError(this.message);
}

class _ModelUnavailable implements Exception {}

class OcrService {
  static const _endpointBase =
      'https://generativelanguage.googleapis.com/v1beta/models';

  static const _prompt =
      'Photo of a phone screen showing an SMS from 9771 (Pakistan Government '
      'fuel relief scheme). Read every digit CAREFULLY, digit by digit. '
      'Extract EVERY token message visible on screen. Return ONLY JSON:\n'
      '{"messages":[{"token_number":"...","vehicle_number":"...",'
      '"amount_pkr":"...","expiry_time":"HH:MM or empty",'
      '"expiry_date":"DD-Mon or empty",'
      '"confidence":{"token_number":0..1,"vehicle_number":0..1}}]}\n'
      'Rules: copy numbers character-by-character EXACTLY as displayed; never '
      'invent digits; if a field is not visible use ""; plates are letters '
      'then digits.';

  // ── Key handling ─────────────────────────────────────────────────────────
  static Future<bool> hasKey() async => (await _key()) != null;

  static Future<String?> _key() async {
    final k = (await DatabaseHelper().getMeta(kOcrKeyMeta))?.trim();
    return (k == null || k.isEmpty) ? null : k;
  }

  // ── ONE photo, ONE request ───────────────────────────────────────────────
  /// Accepts the photo bytes directly so the capture flow stays 100% in
  /// memory — no temp files, no file round-trips.
  static Future<OcrImageResult> extractImage(Uint8List bytes,
      {String label = 'photo'}) async {
    final key = await _key();
    if (key == null) {
      return OcrImageResult(
          imagePath: label,
          ok: false,
          error: 'No OCR key yet — add it in the Settings tab.');
    }
    if (bytes.isEmpty) {
      return OcrImageResult(
          imagePath: label, ok: false, error: 'This photo is empty.');
    }

    // Primary model; on capacity problems (503/500) try the fallback once.
    // Short timeout on the fallback so a dead pool fails in seconds, not
    // minutes — the user gets a Retry button instead of a hang.
    try {
      final text = await _requestModel(kOcrModel, bytes, key);
      return _finish(label, text);
    } on _ModelUnavailable {
      try {
        final text = await _requestModel(kOcrFallbackModel, bytes, key,
            timeoutSeconds: 30);
        return _finish(label, text);
      } catch (e) {
        return _fail(label, e);
      }
    } catch (e) {
      return _fail(label, e);
    }
  }

  static OcrImageResult _fail(String label, Object e) {
    final msg = e is _OcrError ? e.message : 'Could not read this photo. Check internet and retry.';
    return OcrImageResult(imagePath: label, ok: false, error: msg);
  }

  static OcrImageResult _finish(String label, String text) {
    final items = parseGeminiJson(text, label);
    if (items.isEmpty) {
      return OcrImageResult(
          imagePath: label,
          ok: false,
          error: 'No token found on this photo.');
    }
    return OcrImageResult(imagePath: label, ok: true, items: items);
  }

  static Future<String> _requestModel(
      String model, List<int> bytes, String key,
      {int timeoutSeconds = 120}) async {
    final body = jsonEncode({
      'contents': [
        {
          'parts': [
            {'text': _prompt},
            {
              'inline_data': {
                'mime_type': _mimeOf(bytes),
                'data': base64Encode(bytes),
              },
            },
          ],
        },
      ],
      'generationConfig': {'temperature': 0, 'responseMimeType': 'application/json'},
    });
    final http.Response res;
    try {
      res = await http
          .post(Uri.parse('$_endpointBase/$model:generateContent'),
              headers: {
                'Content-Type': 'application/json',
                'x-goog-api-key': key,
              },
              body: body)
          .timeout(Duration(seconds: timeoutSeconds));
    } on SocketException {
      throw _OcrError('No internet — connect and retry.');
    } on TimeoutException {
      throw _OcrError('Reader took too long — retry.');
    }
    switch (res.statusCode) {
      case 200:
        String text = '';
        try {
          final out = jsonDecode(res.body) as Map<String, dynamic>;
          final cands = (out['candidates'] as List?) ?? const [];
          if (cands.isNotEmpty) {
            final first = cands.first as Map;
            final content = (first['content'] as Map?) ?? const {};
            final parts = (content['parts'] as List?) ?? const [];
            if (parts.isNotEmpty) {
              text = ((parts.first as Map)['text'] ?? '').toString();
            }
          }
        } catch (_) {
          throw _OcrError('Reader returned an unreadable answer.');
        }
        if (text.trim().isEmpty) throw _OcrError('Reader returned no text.');
        return text;
      case 401:
      case 403:
        throw _OcrError('The OCR key was rejected — check it in Settings.');
      case 429:
        throw _OcrError('Too many requests — wait a minute and retry.');
      case 500:
      case 503:
        throw _ModelUnavailable();
      default:
        throw _OcrError('Reader error ${res.statusCode}.');
    }
  }

  /// The crop view returns PNG while camera photos are JPEG; labelling PNG
  /// bytes as `image/jpeg` makes Gemini reject the request. Sniff the magic
  /// bytes instead of re-encoding.
  static String _mimeOf(List<int> b) {
    if (b.length >= 8 &&
        b[0] == 0x89 &&
        b[1] == 0x50 &&
        b[2] == 0x4E &&
        b[3] == 0x47) {
      return 'image/png';
    }
    if (b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) {
      return 'image/jpeg';
    }
    if (b.length >= 12 &&
        b[8] == 0x57 &&
        b[9] == 0x45 &&
        b[10] == 0x42 &&
        b[11] == 0x50) {
      return 'image/webp';
    }
    return 'image/jpeg';
  }

  // ── Batch: bulk pick, per-photo processing, live progress ────────────────
  static Future<List<OcrImageResult>> extractBatch(
    List<String> paths, {
    void Function(int done, int total, OcrImageResult result)? onOne,
  }) async {
    final out = <OcrImageResult>[];
    for (var i = 0; i < paths.length; i++) {
      final bytes = await File(paths[i]).readAsBytes();
      final r = await extractImage(bytes, label: paths[i]);
      onOne?.call(i + 1, paths.length, r);
      out.add(r);
      // Small gap keeps well clear of the free tier's per-minute rate.
      if (i + 1 < paths.length) {
        await Future.delayed(const Duration(milliseconds: 300));
      }
    }
    return out;
  }

  // ── Pure logic (fully unit-tested, no network) ───────────────────────────

  /// The model's structured fields become one pseudo-SMS line, which then
  /// runs through the SAME parser the paste flow uses.
  static String pseudoSms({
    required String token,
    required String plate,
    double? amount,
    String time = '',
    String date = '',
  }) {
    final b = StringBuffer('Token Number: $token $plate');
    if (amount != null && amount > 0) b.write(' Rs.${amount.toInt()}');
    if (time.isNotEmpty && date.isNotEmpty) b.write(' till $time $date');
    return b.toString();
  }

  /// "NFF2367" / "NFF 2367" → "NFF-2367" (plate shape: 2-4 letters + digits).
  static String normalizePlate(String raw) {
    final p = raw.trim().toUpperCase().replaceAll(RegExp(r'[\s]+'), ' ');
    final m = RegExp(r'^([A-Z]{2,4})[- ]?(\d{2,5})$').firstMatch(p);
    if (m != null) return '${m.group(1)}-${m.group(2)}';
    return p.replaceAll(' ', '-');
  }

  /// Parses the model's JSON answer into review items. Same token repeated
  /// inside one photo is dropped (kept only once); confidence is the LOWER
  /// of token/vehicle so a single unsure field still flags the card.
  static List<OcrItem> parseGeminiJson(String raw, String sourceImage) {
    final items = <OcrItem>[];
    final List<dynamic> msgs;
    try {
      final data = jsonDecode(raw);
      msgs = ((data is Map ? data['messages'] : null) as List?) ?? const [];
    } catch (_) {
      return items;
    }
    final seen = <String>{};
    for (final m in msgs) {
      if (m is! Map) continue;
      final token =
          (m['token_number'] ?? '').toString().trim().replaceAll(' ', '');
      if (token.isEmpty || !token.contains(RegExp(r'\d'))) continue;
      if (seen.contains(token)) continue;
      seen.add(token);

      final plateRaw = (m['vehicle_number'] ?? '').toString();
      final plate = plateRaw.trim().isEmpty ? '' : normalizePlate(plateRaw);

      double? amount;
      final digitsOnly =
          RegExp(r'(\d+)').firstMatch((m['amount_pkr'] ?? '').toString());
      if (digitsOnly != null) amount = double.tryParse(digitsOnly.group(1)!);

      final time = (m['expiry_time'] ?? '').toString().trim();
      final date = (m['expiry_date'] ?? '').toString().trim();

      double conf = 0.95;
      final c = m['confidence'];
      if (c is Map) {
        final vals = <double>[];
        for (final v in c.values) {
          final d = double.tryParse(v.toString());
          if (d != null) vals.add(d);
        }
        if (vals.isNotEmpty) conf = vals.reduce((a, b) => a < b ? a : b);
      }

      final parsed = SmsParser.parse(pseudoSms(
        token: token,
        plate: plate,
        amount: amount,
        time: time,
        date: date,
      ));
      if (parsed.isEmpty || parsed.first.tokenCode.isEmpty) continue;
      items.add(OcrItem(
          parsed: parsed.first, confidence: conf, sourceImage: sourceImage));
    }
    return items;
  }
}

