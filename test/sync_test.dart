import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:fueltoken_tracker/db/database_helper.dart';
import 'package:fueltoken_tracker/models/token_record.dart';
import 'package:fueltoken_tracker/services/backup_codec.dart';
import 'package:fueltoken_tracker/services/drive_sync_service.dart';

// ── helpers ────────────────────────────────────────────────────────────────
Map<String, dynamic> rec(
  String id, {
  String code = 'C222333444',
  String vehicle = 'NFF-2364',
  int status = 0,
  int? updatedAt = 1000,
  bool deleted = false,
  int? redeemedAt,
  num amount = 500,
}) =>
    {
      'id': id,
      'tokenCode': code,
      'vehicleNumber': vehicle,
      'vehicleType': 0,
      'status': status,
      'dateReceived': 1729000000000,
      'dateImported': 1729000000000,
      'expiryDate': null,
      'subsidyAmount': amount,
      'fuelLitres': 20,
      'litresUsed': 0,
      'originalMessage': 'msg',
      'redeemedAt': redeemedAt,
      'updatedAt': updatedAt,
      'deleted': deleted,
    };

Map<String, dynamic> row(Map<String, dynamic> recordOverrides) {
  final base = rec('seed');
  final r = <String, dynamic>{...base, ...recordOverrides};
  return BackupCodec.recordToRow(r);
}

void main() {
  // ── PURE MERGER TESTS ───────────────────────────────────────────────────────
  group('BackupCodec.merge (pure)', () {
    test('local newer wins — nothing applied, no changes', () {
      final local = [row({'id': 'a', 'updatedAt': 2000})];
      final remote = [rec('a', updatedAt: 1000)];
      final m = BackupCodec.merge(local, remote);
      expect(m.toApply, isEmpty);
      expect(m.changed, isFalse);
      expect(getUpd(m.snapshot.first), 2000);
    });

    test('remote newer wins — record lands in toApply (dirty 0)', () {
      final local = [row({'id': 'a', 'updatedAt': 1000})];
      final remote = [rec('a', updatedAt: 2000, amount: 1000)];
      final m = BackupCodec.merge(local, remote);
      expect(m.changed, isTrue);
      expect(m.toApply, hasLength(1));
      expect(m.toApply.first['dirty'], 0);
      expect(m.snapshot.first['subsidyAmount'], 1000);
    });

    test('tie → local edit stands, nothing pushed back locally', () {
      const tieMs = 5555;
      final local = [row({'id': 'a', 'updatedAt': tieMs, 'dirty': 1})];
      final remote = [rec('a', updatedAt: tieMs)];
      final m = BackupCodec.merge(local, remote);
      expect(m.toApply, isEmpty);
      expect(getUpd(m.snapshot.first), tieMs);
    });

    test('USED is terminal: local-used never resurrected even if remote newer',
        () {
      final local = [
        row({
          'id': 'a',
          'updatedAt': 1000,
          'status': TokenStatus.redeemed.index,
          'redeemedAt': 900,
        }),
      ];
      final remote = [
        rec('a', updatedAt: 2000, status: TokenStatus.active.index),
      ];
      final m = BackupCodec.merge(local, remote);
      expect(m.toApply, isEmpty);
      expect(m.snapshot.first['status'], TokenStatus.redeemed.index);
      expect(m.snapshot.first['redeemedAt'], 900);
    });

    test('remote-USE wins over local-unused even when local is newer', () {
      final local = [
        row({'id': 'a', 'updatedAt': 9000, 'status': TokenStatus.active.index}),
      ];
      final remote = [
        rec('a', updatedAt: 4000, status: TokenStatus.redeemed.index,
            redeemedAt: 3500),
      ];
      final m = BackupCodec.merge(local, remote);
      expect(m.changed, isTrue);
      expect(m.snapshot.first['status'], TokenStatus.redeemed.index);
      expect(m.snapshot.first['redeemedAt'], 3500);
    });

    test('remote tombstone deletes the local row', () {
      final local = [row({'id': 'a', 'updatedAt': 1000, 'deleted': 0})];
      final remote = [rec('a', updatedAt: 3000, deleted: true)];
      final m = BackupCodec.merge(local, remote);
      expect(m.toApply, hasLength(1));
      expect(m.toApply.first['deleted'], 1);
      expect(m.snapshot.first['deleted'], isTrue);
    });

    test('deleting then UNDO-restoring (local newer) beats tombstone', () {
      final local = [
        row({'id': 'a', 'updatedAt': 4000, 'deleted': 0}), // restored later
      ];
      final remote = [rec('a', updatedAt: 3000, deleted: true)];
      final m = BackupCodec.merge(local, remote);
      expect(m.toApply, isEmpty);
      expect(m.snapshot.first['deleted'], isFalse);
    });

    test('remote-only record materializes locally; local-only joins snapshot',
        () {
      final local = [row({'id': 'only-local', 'updatedAt': 1})];
      final remote = [rec('only-remote', updatedAt: 2)];
      final m = BackupCodec.merge(local, remote);
      expect(m.toApply.single['id'], 'only-remote');
      expect(m.snapshot.map((r) => r['id']),
          containsAll(['only-local', 'only-remote']));
    });

    test('double-merge stability: applying the merge then re-merging no-ops',
        () {
      final local = [row({'id': 'a', 'updatedAt': 1000})];
      final remote = [rec('a', updatedAt: 2000, amount: 750)];
      final first = BackupCodec.merge(local, remote);
      expect(first.changed, isTrue);

      final second =
          BackupCodec.merge([first.toApply.first], remote);
      expect(second.changed, isFalse,
          reason: 'idempotent second pass must not re-apply');
    });
  });

  group('BackupCodec codec roundtrip (JSON-safe types)', () {
    test('all columns survive row → record → row', () {
      final original = row({
        'id': 'x1',
        'updatedAt': 987654321234,
        'subsidyAmount': 999.5,
        'expiryDate': 1600000000000,
        'redeemedAt': 1600000009999,
        'status': 1,
      });
      final asRecord = BackupCodec.rowToRecord(original);
      final encoded = jsonEncode(asRecord); // must be JSON-typable
      final decoded = jsonDecode(encoded) as Map<String, dynamic>;
      final back = BackupCodec.recordToRow(decoded);
      for (final key in [
        'id',
        'updatedAt',
        'subsidyAmount',
        'expiryDate',
        'redeemedAt',
        'status',
        'tokenCode',
        'vehicleNumber',
      ]) {
        expect(back[key], original[key], reason: 'field $key must roundtrip');
      }
      expect(back['dirty'], 0);
      expect(back['weekNumber'], isNotNull);
      expect(back['weekYear'], isNotNull);
    });

    test('torn/garbage download never crashes the parser', () {
      expect(BackupCodec.parseEnvelope('ntjhs'), isEmpty);
      expect(BackupCodec.parseEnvelope({'records': 'nope'}), isEmpty);
      expect(BackupCodec.parseEnvelope({'records': [1, 'x']}), isEmpty);
    });

    test('envelope carries schema version + device name', () {
      final env = BackupCodec.buildEnvelope(
          records: [], deviceName: 'Redmi 12C', lastSyncedAtMs: 5);
      expect(env['schemaVersion'], kBackupSchemaVersion);
      expect(env['deviceName'], 'Redmi 12C');
      expect(env['records'], isEmpty);
    });

    test('notes and cnic survive the wire (REPLACE must not wipe them)', () {
      final original = row({
        'id': 'n1',
        'personName': 'Ali',
        'mobileNumber': '03001234567',
        'cnic': '42101-1234567-1',
        'notes': 'Owner: Ali — pump 3',
      });
      final wire = jsonDecode(jsonEncode(BackupCodec.rowToRecord(original)))
          as Map<String, dynamic>;
      final back = BackupCodec.recordToRow(wire);
      expect(back['cnic'], '42101-1234567-1');
      expect(back['notes'], 'Owner: Ali — pump 3');
      expect(back['personName'], 'Ali');
      expect(back['mobileNumber'], '03001234567');
    });

    test('recordsHash agrees for a DB row and its JSON record', () {
      final dbRow = row({
        'id': 'h1',
        'subsidyAmount': 500.0, // SQLite REAL
        'expiryDate': 1800000000000,
        'litresUsed': null, // NULL in DB
      });
      final wire = BackupCodec.parseEnvelope({
        'records': [
          {
            ...BackupCodec.rowToRecord(dbRow),
            'subsidyAmount': 500, // JSON round-trip: int, not 500.0
            'litresUsed': 0,
            'personName': null, // explicit null from an older writer
          }
        ]
      }).single;

      expect(BackupCodec.recordsHash([dbRow]),
          BackupCodec.recordsHash([wire]),
          reason: 'int/double and null/absent must not change the fingerprint');
    });

    test('parseEnvelope strips explicit nulls', () {
      final parsed = BackupCodec.parseEnvelope({
        'records': [
          {'id': 'x', 'personName': null, 'notes': null, 'deleted': false}
        ]
      }).single;
      expect(parsed.containsKey('personName'), isFalse);
      expect(parsed.containsKey('notes'), isFalse);
    });

    test('missing dateImported falls back to dateReceived, not wall clock', () {
      final r = BackupCodec.recordToRow({
        'id': 'd1',
        'dateReceived': 1729000000000,
      });
      expect(r['dateImported'], 1729000000000);
    });

    test('fast-path invariant: local hash == pushed hash == downloaded hash',
        () {
      final local = [row({'id': 'p1', 'subsidyAmount': 500.0})];
      final merge = BackupCodec.merge(local, const []);
      final pushed = BackupCodec.recordsHash(merge.snapshot);

      expect(BackupCodec.recordsHash(local), pushed,
          reason: 'next launch must be able to skip work (pushedHash==localHash)');

      final envelope = BackupCodec.buildEnvelope(
          records: merge.snapshot, deviceName: 'x', lastSyncedAtMs: 1);
      final downloaded = BackupCodec.parseEnvelope(
          jsonDecode(jsonEncode(envelope)) as Map<String, dynamic>);
      expect(BackupCodec.recordsHash(downloaded), pushed,
          reason: 'another device must see the same fingerprint');
    });
  });

  group('SyncText labels', () {
    test('lastSyncedLabel formats a usable stamp', () {
      final t = DateTime(2026, 10, 21, 16, 47);
      final label = SyncText.lastSyncedLabel(t);
      expect(label, contains('21-Oct'));
      expect(label, contains('4:47pm'));
      expect(SyncText.lastSyncedLabel(null), 'Never');
    });
  });

  // ── DB-BACKED SYNC TESTS (ffi sqlite) ──────────────────────────────────────
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  TokenRecord dbToken(String code) {
    final now = DateTime.now();
    return TokenRecord(
      id: 'sync-$code',
      tokenCode: code,
      vehicleNumber: 'VSYNC-1',
      vehicleType: VehicleType.motorcycle,
      status: TokenStatus.active,
      dateReceived: now,
      dateImported: now,
      subsidyAmount: 500.0,
      fuelLitres: 20,
    );
  }

  group('DatabaseHelper sync columns (ffi db)', () {
    test('insert marks dirty=1; tombstones survive snapshot but hide from UI',
        () async {
      final db = DatabaseHelper();
      final t = dbToken('DIRTY0001');
      await db.insertToken(t);
      final rows = await db.getSyncSnapshot();
      final mine = rows.firstWhere((r) => r['id'] == 'sync-DIRTY0001');
      expect(mine['dirty'], 1);
      expect((mine['updatedAt'] as int) > 0, isTrue);
      expect(mine['deleted'], 0);

      await db.deleteTokens(['sync-DIRTY0001']);
      final afterDelete = (await db.getSyncSnapshot())
          .where((r) => r['id'] == 'sync-DIRTY0001')
          .toList();
      expect(afterDelete.isNotEmpty, isTrue,
          reason: 'tombstone row must survive (merge visibility)');
      expect((afterDelete.first['deleted'] as int), 1);

      // User-facing queries must NOT see it:
      expect((await db.getAllTokens()).any((t) => t.id == 'sync-DIRTY0001'),
          isFalse);
      expect(await db.tokenCodeExists('DIRTY0001'), isFalse,
          reason: 'duplicate guard ignores tombstones');

      await db.restoreTokens(['sync-DIRTY0001']);
      expect(
          (await db.getAllTokens()).any((t) => t.id == 'sync-DIRTY0001'),
          isTrue,
          reason: 'UNDO restore revives the token');
      final revived = (await db.getSyncSnapshot())
          .firstWhere((r) => r['id'] == 'sync-DIRTY0001');
      expect(revived['deleted'], 0);
      expect(revived['dirty'], 1, reason: 'revival must re-sync');
    });

    test('applyRemoteRecords writes clean synced rows (dirty=0)', () async {
      final db = DatabaseHelper();
      final remoteWon = BackupCodec.recordToRow(
          rec('remote-wins-77', updatedAt: 123456, amount: 800));
      await db.applyRemoteRecords([remoteWon]);
      final loaded = (await db.getSyncSnapshot())
          .firstWhere((r) => r['id'] == 'remote-wins-77');
      expect(loaded['dirty'], 0);
      expect(loaded['updatedAt'], 123456);
      expect(loaded['subsidyAmount'], 800);
    });

    test('meta table roundtrip', () async {
      final db = DatabaseHelper();
      await db.setMeta('k1', 'v1');
      expect(await db.getMeta('k1'), 'v1');
      await db.setMeta('k1', 'v2'); // replace
      expect(await db.getMeta('k1'), 'v2');
    });
  });
}

int getUpd(Map<String, dynamic> rec) => (rec['updatedAt'] as num?)?.toInt() ?? -1;
