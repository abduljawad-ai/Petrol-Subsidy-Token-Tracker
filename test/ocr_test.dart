import 'package:flutter_test/flutter_test.dart';
import 'package:fueltoken_tracker/services/ocr_service.dart';
import 'package:fueltoken_tracker/services/sms_parser.dart';

void main() {
  test('pseudo SMS runs through SmsParser: token + plate + amount + expiry', () {
    final t = OcrService.pseudoSms(
      token: '6622336332',
      plate: 'NFF-2367',
      amount: 500,
      time: '09:24',
      date: '25-Oct',
    );
    final r = SmsParser.parse(t);
    expect(r, isNotEmpty);
    expect(r.first.unrecognised, false);
    expect(r.first.tokenCode, '6622336332');
    expect(r.first.vehicleNo, 'NFF-2367');
    expect(r.first.reliefAmount, 500.0);
    expect(r.first.expiryDisplay, '25-Oct, 09:24');
  });

  test('pseudo SMS without visible expiry still parses token + plate', () {
    final t = OcrService.pseudoSms(
      token: '2269836307',
      plate: 'NFF-2371',
      amount: 500,
    );
    final r = SmsParser.parse(t);
    expect(r.first.tokenCode, '2269836307');
    expect(r.first.vehicleNo, 'NFF-2371');
    expect(r.first.expiryDisplay, isNull);
  });

  test('normalizePlate inserts the hyphen (NFF2367 -> NFF-2367)', () {
    expect(OcrService.normalizePlate('NFF2367'), 'NFF-2367');
    expect(OcrService.normalizePlate('nff 2367'), 'NFF-2367');
    expect(OcrService.normalizePlate('NFC-7043'), 'NFC-7043');
  });

  test('parseGeminiJson: extraction, amount "Rs500", confidence flagging', () {
    const json = '{"messages":['
        '{"token_number":"6622336332","vehicle_number":"NFF-2367",'
        '"amount_pkr":"Rs500","expiry_time":"09:24","expiry_date":"25-Oct",'
        '"confidence":{"token_number":0.99,"vehicle_number":0.98}},'
        '{"token_number":"2261198400","vehicle_number":"NFF2369",'
        '"amount_pkr":"500","expiry_time":"","expiry_date":"",'
        '"confidence":{"token_number":0.7}}'
        ']}';
    final items = OcrService.parseGeminiJson(json, 'img.jpg');
    expect(items.length, 2);
    // first: high confidence, full data -> no review flag
    expect(items[0].needsCheck, false);
    expect(items[0].parsed.tokenCode, '6622336332');
    expect(items[0].parsed.vehicleNo, 'NFF-2367');
    expect(items[0].parsed.reliefAmount, 500.0);
    expect(items[0].parsed.expiryDisplay, '25-Oct, 09:24');
    // second: confidence below 0.9 -> amber "Check this"
    expect(items[1].needsCheck, true);
    expect(items[1].confidence, 0.7);
    expect(items[1].parsed.vehicleNo, 'NFF-2369');
  });

  test('parseGeminiJson: same token repeated in one photo is dropped', () {
    const json = '{"messages":['
        '{"token_number":"6622336332","vehicle_number":"NFF-2367","amount_pkr":"500","expiry_time":"","expiry_date":""},'
        '{"token_number":"6622336332","vehicle_number":"NFF-2367","amount_pkr":"500","expiry_time":"","expiry_date":""}'
        ']}';
    final items = OcrService.parseGeminiJson(json, 'img.jpg');
    expect(items.length, 1);
  });

  test('parseGeminiJson: wrong-length token (dropped digit) is flagged', () {
    // This is exactly what DeepRead did wrong on WA0003 — the shape check
    // must catch it so the card is never saved without review.
    const json = '{"messages":['
        '{"token_number":"226119840","vehicle_number":"NFF-2369",'
        '"amount_pkr":"500","expiry_time":"","expiry_date":""}'
        ']}';
    final items = OcrService.parseGeminiJson(json, 'x.jpg');
    expect(items, isNotEmpty);
    expect(items.first.parsed.tokenCode, '226119840');
    expect(items.first.needsCheck, true);
  });

  test('parseGeminiJson: token with no plate flagged; garbage input safe', () {
    const noPlate = '{"messages":['
        '{"token_number":"5302570854","vehicle_number":"","amount_pkr":"500",'
        '"expiry_time":"","expiry_date":""}]}';
    expect(OcrService.parseGeminiJson(noPlate, 'x.jpg').first.needsCheck, true);

    expect(OcrService.parseGeminiJson('not json at all', 'x.jpg'), isEmpty);
    expect(OcrService.parseGeminiJson('{"messages":[]}', 'x.jpg'), isEmpty);
    expect(OcrService.parseGeminiJson('{"other":1}', 'x.jpg'), isEmpty);
  });
}
