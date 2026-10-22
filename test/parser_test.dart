import 'package:flutter_test/flutter_test.dart';
import 'package:fueltoken_tracker/services/sms_parser.dart';

const urduSample =
    'آپ ٹوکن نمبر 8401712225 سے سواری نمبر NFF-2364 کے لیے 500 روپے کا فیول ریلیف حاصل کر سکتے ہیں۔ یہ ٹوکن 16:47 25-Oct تک قابلِ استعمال ہے۔';
void main() {
  test('Urdu 9771 SMS: full extraction', () {
    final r = SmsParser.parse(urduSample);
    expect(r.length, 1);
    expect(r.first.unrecognised, false);
    expect(r.first.tokenCode, '8401712225');
    expect(r.first.vehicleNo, 'NFF-2364');
    expect(r.first.reliefAmount, 500.0);
    expect(r.first.expiryDisplay, '25-Oct, 16:47');
  });

  test('Urdu expiry parses to correct year/month/day/time', () {
    final r = SmsParser.parse(urduSample);
    final d = r.first.expiryDate!;
    final now = DateTime.now();
    expect(d.year, now.year);
    expect(d.month, 10);
    expect(d.day, 25);
    expect(d.hour, 16);
    expect(d.minute, 47);
  });

  test('RESCUE: incomplete fragment without the ٹوکن label still finds token + plate', () {
    const frag = 'نمبر 5271049386 سے سواری نمبر NFC-7043';
    final r = SmsParser.parse(frag);
    expect(r, isNotEmpty);
    expect(r.first.unrecognised, isFalse);
    expect(r.first.tokenCode, '5271049386');
    expect(r.first.vehicleNo, 'NFC-7043');
  });

  test('RESCUE: bare 10-digit run without any label', () {
    const frag = '5271049386';
    final r = SmsParser.parse(frag);
    expect(r, isNotEmpty);
    expect(r.first.tokenCode, '5271049386');
  });

  test('RESCUE never swallows CNIC-style digit runs (13 digits)', () {
    const frag = 'CNIC 3520212345671 expired doc';
    final r = SmsParser.parse(frag);
    expect(r.any((x) => x.tokenCode == '3520212345'), isFalse);
    expect(r.any((x) => x.tokenCode == '35202123456'), isFalse);
  });

  test('English "Token Number: ..." captures the digits, not the word NUMBER', () {
    // Regression: old regex captured "NUMBER" here.
    const msg = 'Token Number: 8200145677 Vehicle: NFC-7035 Rs. 500 valid till 21:59 24-Oct';
    final r = SmsParser.parse(msg);
    expect(r.length, 1);
    expect(r.first.tokenCode, '8200145677');
    expect(r.first.vehicleNo, 'NFC-7035');
    expect(r.first.reliefAmount, 500.0);
    expect(r.first.expiryDate!.hour, 21);
    expect(r.first.expiryDate!.minute, 59);
  });

  test('English alnum "Token: ABC123" and label formats', () {
    const msg = 'Token: ABC123 · Lea-4567 · Rs150 · till 09:30 12-Nov';
    final r = SmsParser.parse(msg);
    expect(r.first.tokenCode, 'ABC123');
  });

  test('Vehicle type hint detected from SMS wording (plates do not encode type)', () {
    final bike = SmsParser.parse(
        'آپ ٹوکن نمبر 1111222233 سے سواری نمبر NFF-2364 کے لیے 500 روپے کا موٹر سائیکل فیول ریلیف حاصل کر سکتے ہیں۔');
    expect(bike.first.vehicleTypeHint, 'motorcycle');

    final car = SmsParser.parse('Token Number: 5555666677 Car ABC-123 Rs.500 straight: use till 10:00 05-Nov');
    expect(car.first.vehicleTypeHint, 'smallCar');

    final rickshaw = SmsParser.parse('Token Number: 5555666678 Rick LEA-4567 Rs.500 rickshaw till 10:00 05-Nov');
    expect(rickshaw.first.vehicleTypeHint, 'rickshaw');

    final unspecified = SmsParser.parse(urduSample);
    expect(unspecified.first.vehicleTypeHint, isNull,
        reason: 'no wording → null so caller keeps program default, no guessing');
  });

  test('Forwarded batch: one message per line, all extracted', () {
    // Regression: old code treated the entire block as ONE message and
    // silently dropped every token except the first.
    const batch = '$urduSample\n'
        'آپ ٹوکن نمبر 9871998277 سے سواری نمبر NFC-7035 کے لیے 500 روپے کا فیول ریلیف حاصل کر سکتے ہیں۔ یہ ٹوکن 21:59 24-Oct تک قابلِ استعمال ہے۔\n'
        'Token Number: 7001122334 Lea-4567';
    final r = SmsParser.parse(batch);
    expect(r.where((e) => !e.unrecognised).length, 3);
    expect(r.map((e) => e.tokenCode), containsAll([
      '8401712225', '9871998277', '7001122334'
    ]));
  });

  test('Quoted batch extraction', () {
    const batch = '"Token Number: 1111222233 Lea-4567 Rs. 500",\n'
        '"Token Number: 4444555566 Lea-9871 Rs. 500"';
    final r = SmsParser.parse(batch);
    expect(r.length, 2);
    expect(r[0].tokenCode, '1111222233');
    expect(r[1].tokenCode, '4444555566');
  });

  test('Unknown month abbreviation → no expiry, token still detected', () {
    const msg = 'Token Number: 8200145677 Lea-4567 valid till 09:00 12-Xyz';
    final r = SmsParser.parse(msg);
    expect(r.first.tokenCode, '8200145677');
    expect(r.first.expiryDate, isNull);
  });

  test('Impossible date "31-Feb" → no expiry (no silent month rollover)', () {
    const msg = 'Token Number: 8200145677 Lea-4567 till 09:00 31-Feb';
    final r = SmsParser.parse(msg);
    expect(r.first.expiryDate, isNull);
  });

  test('Garbage text is flagged unrecognised, not saved as a token', () {
    final r = SmsParser.parse('hey did you watch the match last night??');
    expect(r.length, 1);
    expect(r.first.unrecognised, true);
    expect(r.first.tokenCode, isEmpty);
  });

  test('Dec SMS expiring in Jan rolls year forward', () {
    // Inject a fake "now" is not possible with pure statics; instead verify
    // the documented rollover via parseExpiry when current month is Dec.
    final now = DateTime.now();
    final expiry = SmsParser.parseExpiry('10:00', '05-Jan');
    if (now.month == 12) {
      expect(expiry!.year, now.year + 1);
    } else {
      expect(expiry!.year, now.year);
    }
    expect(expiry.month, 1);
    expect(expiry.day, 5);
    expect(expiry.hour, 10);
  });

  // ═══ Messy forwarded WhatsApp text (regression group) ════════════════════
// Real-world paste: per-message header prefixes "[d/m, h:mm am/pm] Name:",
// nested double headers from extra forwards, RTL control chars around the
// time ("‎21:59 24-Oct‏"), and the SAME token repeated many times across the
// batch. Requirements: every token pairs with ITS OWN plate & expiry, no
// cross-message mixing, and repeats are collapsed at parse time.
const line1 = '[17/10, 10:08 pm] Jawad: آپ ٹوکن نمبر 9871998277 سے سواری نمبر NFC-7035 کے لیے 500 روپے کا فیول ریلیف حاصل کر سکتے ہیں۔ یہ ٹوکن ‎21:59 24-Oct‏ تک قابلِ استعمال ہے۔';
  const line2 = '[18/10, 4:47 pm] Jawad: آپ ٹوکن نمبر 8401712225 سے سواری نمبر NFF-2364 کے لیے 500 روپے کا فیول ریلیف حاصل کر سکتے ہیں۔ یہ ٹوکن 16:47 25-Oct تک قابلِ استعمال ہے۔';
  const line3 = '[20/10, 11:33 pm] Jawad: آپ ٹوکن نمبر 5597339971 سے سواری نمبر NFC-7034 کے لیے 500 روپے کا فیول ریلیف حاصل کر سکتے ہیں۔ یہ ٹوکن ‎22:04 24-Oct‏ تک قابلِ استعمال ہے۔';  const line4 = '[20/10, 11:33 pm] Jawad: آپ ٹوکن نمبر 9871998277 سے سواری نمبر NFC-7035 کے لیے 500 روپے کا فیول ریلیف حاصل کر سکتے ہیں۔ یہ ٹوکن ‎21:59 24-Oct‏ تک قابلِ استعمال ہے۔';

  test('WhatsApp batch: 4 headered lines, headers stripped, all pairs intact', () {
    final r = SmsParser.parse('$line1\n$line2\n$line3\n$line4');
    // 4 physical messages → 4 results (dupes collapsed later, not here).
    expect(r.length, 4);
    expect(r.every((e) => !e.unrecognised), isTrue,
        reason: 'stripped headers must not leave junk cards behind');

    // ── PAIR FIDELITY: token ↔ plate ↔ expiry must match its own message ──
    final hits = r.where((e) => e.tokenCode == '8401712225').toList();
    expect(hits, hasLength(1));
    expect(hits.first.vehicleNo, 'NFF-2364',
        reason: '8401712225 must carry ITS plate, not a neighbour’s');
    expect(hits.first.expiryDisplay, '25-Oct, 16:47');

    final hits9871 = r.where((e) => e.tokenCode == '9871998277').toList();
    expect(hits9871, hasLength(2), reason: 'appears twice physically');
    for (final h in hits9871) {
      expect(h.vehicleNo, 'NFC-7035');
      expect(h.expiryDisplay, '24-Oct, 21:59');
    }

    final hit5597 = r.where((e) => e.tokenCode == '5597339971').toList();
    expect(hit5597, hasLength(1));
    expect(hit5597.first.vehicleNo, 'NFC-7034');
    expect(hit5597.first.expiryDisplay, '24-Oct, 22:04');
  });

  test('WhatsApp batch: repeated token is auto-collapsed at parse time', () {
    final r = SmsParser.parse('$line1\n$line2\n$line3\n$line4');
    final dups = r.where((e) => e.dupInBatch).toList();
    expect(dups, hasLength(1),
        reason: 'only the SECOND 9871998277 is the in-batch duplicate');
    expect(dups.first.skip, isTrue);
    expect(dups.first.dupInBatch, isTrue);

    // Everything else untouched.
    final firsts = r.where((e) => !e.dupInBatch).toList();
    expect(firsts, hasLength(3));
    // Cross-check the skip flags did not leak onto first occurrences.
    expect(firsts.every((e) => e.skip == false), isTrue);
  });

  test('RTL markers around the time do not block expiry parsing', () {
    // "‎21:59 24-Oct‏" — U+200E prefix + U+200F suffix must be stripped
    // before the matchers run.
    final r = SmsParser.parse(line1);
    expect(r, hasLength(1));
    expect(r.first.expiryDisplay, '24-Oct, 21:59');
    expect(r.first.expiryDate, isNotNull);
  });

  test('nested double-header forward: both prefixes removed in one pass', () {
    const nested = '[21/10, 12:46 am] Jawad: $line1\n$line2';
    final r = SmsParser.parse(nested);
    expect(r, hasLength(2));
    expect(r.where((e) => e.unrecognised), isEmpty,
        reason: 'a leftover header fragment must not surface as junk');
    expect(r.first.tokenCode, '9871998277');
    expect(r.first.vehicleNo, 'NFC-7035');

    final second = r.where((e) => e.tokenCode == '8401712225').toList();
    expect(second, hasLength(1));
    expect(second.first.dupInBatch, isFalse,
        reason: 'different token re-forwarded is NOT a duplicate');
  });

  test('OCR line-wrap: expiry on its own line still lands on its message', () {
    // Small screens wrap a message; the tail must join back to ITS token,
    // never to the next one, and must not become an "unrecognised" card.
    final wrappedHead = line1.split('یہ ٹوکن')[0]; // message cut mid-sentence
    final wrapped = '$wrappedHead\nیہ ٹوکن ‎21:59 24-Oct‏ تک قابلِ استعمال ہے۔\n$line2';
    final r = SmsParser.parse(wrapped);
    final real = r.where((e) => !e.unrecognised).toList();
    expect(real, hasLength(2), reason: 'no junk card from the wrapped tail');
    expect(r.where((e) => e.unrecognised), isEmpty);
    expect(real.first.tokenCode, '9871998277');
    expect(real.first.expiryDisplay, '24-Oct, 21:59',
        reason: 'tail rejoins its own message');
    expect(real.last.tokenCode, '8401712225');
    expect(real.last.expiryDisplay, '25-Oct, 16:47',
        reason: 'next message unaffected by previous tail');
  });

  test('interleaved wraps: plates pulled from the WRONG message is the bug — none allowed', () {
    // Hardest case: two messages, each wrapped such that the NEXT message's
    // token marker starts before the previous tail would naively merge.
    const a = 'آپ ٹوکن نمبر 9871998277 سے سواری نمبر NFC-7035 کے لیے 500 روپے کا فیول ریلیف حاصل کر سکتے ہیں۔';
    const aTail = 'یہ ٹوکن 21:59 24-Oct تک قابلِ استعمال ہے۔';
    const b = 'آپ ٹوکن نمبر 8401712225 سے سواری نمبر NFF-2364 کے لیے 500 روپے کا فیول ریلیف حاصل کر سکتے ہیں۔';
    const bTail = 'یہ ٹوکن 16:47 25-Oct تک قابلِ استعمال ہے۔';
    final r = SmsParser.parse('$a\n$aTail\n$b\n$bTail');
    expect(r, hasLength(2));
    expect(r.first.tokenCode, '9871998277');
    expect(r.first.vehicleNo, 'NFC-7035');
    expect(r.first.expiryDisplay, '24-Oct, 21:59');
    expect(r.last.tokenCode, '8401712225');
    expect(r.last.vehicleNo, 'NFF-2364');
    expect(r.last.expiryDisplay, '25-Oct, 16:47');
  });

  test('English token inside a WhatsApp headered batch still parses', () {
    const mixed = '$line1\n[18/10, 5:02 pm] Jawad: Token Number: 802014567\n$line3';
    final r = SmsParser.parse(mixed);
    expect(r.where((e) => !e.unrecognised).length, 3);
    final en = r.where((e) => e.tokenCode == '802014567').toList();
    expect(en, hasLength(1));
    expect(en.first.dupInBatch, isFalse);
  });

  test('whole-paste dedupe: same 9871998277 across 4 repeats → only 1 saveable', () {
    const quartet = '$line1\n$line4\n$line1\n$line4';
    final r = SmsParser.parse(quartet);
    final saveable = r.where((e) => !e.dupInBatch && !e.skip).length;
    expect(saveable, 1, reason: 'all repeats collapse to the first occurrence');
  });
}
