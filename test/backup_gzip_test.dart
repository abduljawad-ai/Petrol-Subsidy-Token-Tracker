import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fueltoken_tracker/services/backup_codec.dart';

void main() {
  test('gzip detection recognizes GZIP magic and plain JSON', () {
    final gz = gzip.encode(utf8.encode('{"a":1}'));
    expect(BackupCodec.isGzipped(gz), isTrue);
    expect(BackupCodec.isGzipped(utf8.encode('{"a":1}')), isFalse);
    expect(BackupCodec.isGzipped(const []), isFalse);
  });

  test('recordsHash is stable and content-sensitive', () {
    final a = BackupCodec.recordsHash([
      {'tokenCode': 'ABC', 'updatedAt': 100},
      {'tokenCode': 'ZZZ', 'updatedAt': 50},
    ]);
    // Same rows, different key order → same hash (canonical encoding).
    final b = BackupCodec.recordsHash([
      {'updatedAt': 100, 'tokenCode': 'ABC'},
      {'updatedAt': 50, 'tokenCode': 'ZZZ'},
    ]);
    expect(a, b);
    // Real change → different hash.
    final c = BackupCodec.recordsHash([
      {'tokenCode': 'ABC', 'updatedAt': 101},
      {'tokenCode': 'ZZZ', 'updatedAt': 50},
    ]);
    expect(c, isNot(a));
  });

  test('gzip round-trip keeps an envelope intact and much smaller', () {
    final records = List.generate(40, (i) => <String, dynamic>{
          'tokenCode': 'TOKEN${10000000 + i}',
          'vehicleNumber': 'ABC-12$i',
          'updatedAt': 1750000000000 + i,
          'deleted': false,
        });
    final envelope = BackupCodec.buildEnvelope(
      records: records,
      deviceName: 'test-device',
      lastSyncedAtMs: 1750000000000,
    );
    final plain = utf8.encode(jsonEncode(envelope));
    final gz = gzip.encode(plain);
    expect(gz.length, lessThan((plain.length / 2).ceil()),
        reason: 'gzip must save at least half the bytes for token JSON');
    expect(BackupCodec.isGzipped(gz), isTrue);
    // Legacy plain payload still decodes.
    expect(BackupCodec.isGzipped(plain), isFalse);
    final back = jsonDecode(utf8.decode(gzip.decode(gz)));
    expect(BackupCodec.parseEnvelope(back).length, records.length);
  });
}
