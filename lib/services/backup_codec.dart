import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

import '../models/token_record.dart';

/// Pure-Dart layer between the SQLite rows and the Drive backup file.
/// No Flutter, no network — fully unit-testable.

/// ---- The backup file envelope (schema 1) -------------------------------
/// ```json
/// {"schemaVersion":1,"deviceName":"…","lastSyncedAt":…,
///  "records":[ { ...token fields..., "updatedAt":…, "deleted":false } ]}
/// ```
/// Only sync-relevant columns travel over the wire; derived week fields and
/// local flags (`dirty`) are never uploaded — they're recomputed locally.

const int kBackupSchemaVersion = 1;
const String kBackupFileName = 'fueltoken_backup.json';

/// Compressed era of the backup file. Content is GZIP bytes (the JSON
/// squashes 3-5x); the legacy plain-JSON file stays readable forever.
const String kBackupFileGzName = 'fueltoken_backup.json.gz';

const int kGzipMagic0 = 0x1f;
const int kGzipMagic1 = 0x8b;

/// Result of merging a local snapshot against the remote snapshot.
class SyncMerge {
  /// Remote-won rows, already in FULL DB-column shape (`dirty` forced 0),
  /// ready for DatabaseHelper.applyRemoteRecords.
  final List<Map<String, dynamic>> toApply;

  /// The complete merged snapshot as JSON-ready records (both sides'
  /// freshest state, tombstones included).
  final List<Map<String, dynamic>> snapshot;

  /// True when the local DB actually needs changes applied.
  final bool changed;

  const SyncMerge(this.toApply, this.snapshot, this.changed);
}

class BackupCodec {
  /// Stable fingerprint of a snapshot, normalized through [rowToRecord] so a
  /// raw DB row and the JSON record made from it always hash identically.
  /// Without this the engine's "nothing changed" fast path can never hit.
  static String recordsHash(List<Map<String, dynamic>> records) =>
      recordsHashImpl(records.map(rowToRecord).toList());

  /// GZIP payload detection (delegates to the top-level helper).
  static bool isGzipped(List<int> bytes) => isGzippedImpl(bytes);
  BackupCodec._();

  static const List<String> _fields = [
    'id',
    'tokenCode',
    'vehicleNumber',
    'vehicleType',
    'personName',
    'mobileNumber',
    'cnic',
    'status',
    'dateReceived',
    'dateImported',
    'expiryDate',
    'subsidyAmount',
    'fuelLitres',
    'litresUsed',
    'originalMessage',
    'notes',
    'redeemedAt',
    'updatedAt',
    'deleted',
  ];

  /// DB row → JSON record (whitelisted fields + real types).
  static Map<String, dynamic> rowToRecord(Map<String, dynamic> row) {
    final rec = <String, dynamic>{};
    for (final f in _fields) {
      final v = row[f];
      if (f == 'deleted') {
        rec[f] = _asDeleted(v);
        continue;
      }
      // NULL and 0 both mean "nothing used"; emitting one canonical value
      // keeps a NULL row and a 0 row hashing/merging identically.
      if (f == 'litresUsed') {
        rec[f] = (v as num?)?.toInt() ?? 0;
        continue;
      }
      if (v == null) continue;
      rec[f] = v;
    }
    rec['updatedAt'] ??= row['dateImported'] ?? 0;
    rec['deleted'] ??= false;
    return rec;
  }

  /// JSON record → DB row for upsert. Derives week columns; forces dirty=0
  /// unless overridden (the merger may push a record that still carries the
  /// local dirty flag).
  static Map<String, dynamic> recordToRow(
    Map<String, dynamic> rec, {
    int dirty = 0,
  }) {
    final received = (rec['dateReceived'] as num?)?.toInt() ?? 0;
    final receivedDate =
        DateTime.fromMillisecondsSinceEpoch(received, isUtc: false);
    final row = <String, dynamic>{
      'id': rec['id'] as String,
      'tokenCode': (rec['tokenCode'] as String?) ?? '',
      'vehicleNumber': (rec['vehicleNumber'] as String?) ?? '',
      'vehicleType': (rec['vehicleType'] as num?)?.toInt() ?? 0,
      'status': (rec['status'] as num?)?.toInt() ?? 0,
      'dateReceived': received,
      'dateImported': (rec['dateImported'] as num?)?.toInt() ?? received,
      'expiryDate': rec['expiryDate'],
      'subsidyAmount': rec['subsidyAmount'],
      'fuelLitres': rec['fuelLitres'],
      'litresUsed': (rec['litresUsed'] as num?)?.toInt() ?? 0,
      'originalMessage': rec['originalMessage'],
      'redeemedAt': rec['redeemedAt'],
      'updatedAt': (rec['updatedAt'] as num?)?.toInt() ?? 0,
      'deleted': _asDeleted(rec['deleted']) ? 1 : 0,
      'dirty': dirty,
      'weekNumber': _weekOfYear(receivedDate),
      'weekYear': receivedDate.year,
    };
    // Optional text fields survive rejection of nulls in JSON.
    row['personName'] = rec['personName'];
    row['mobileNumber'] = rec['mobileNumber'];
    row['cnic'] = rec['cnic'];
    row['notes'] = rec['notes'];
    return row;
  }

  /// Whole-file envelope from merge-ready JSON records.
  static Map<String, dynamic> buildEnvelope({
    required List<Map<String, dynamic>> records,
    required String deviceName,
    required int lastSyncedAtMs,
  }) {
    return {
      'schemaVersion': kBackupSchemaVersion,
      'deviceName': deviceName,
      'lastSyncedAt': lastSyncedAtMs,
      'records': records,
    };
  }

  /// Parses a downloaded envelope; tolerates garbage (returns empty).
  /// Nulls are stripped so a record has exactly the shape [rowToRecord]
  /// produces — otherwise the same row hashes differently on each side.
  static List<Map<String, dynamic>> parseEnvelope(dynamic decoded) {
    try {
      if (decoded is! Map<String, dynamic>) return [];
      final records = decoded['records'];
      if (records is! List) return [];
      return records.whereType<Map>().map((r) {
        return Map<String, dynamic>.from(r)
          ..removeWhere((_, v) => v == null);
      }).toList();
    } catch (_) {
      return [];
    }
  }

  // ── THE MERGE ────────────────────────────────────────────────────────────────
  /// Per-record union, newest `updatedAt` wins (ties → local, because a fresh
  /// local edit that hasn't pushed yet is by definition newer). Guards:
  ///  - a USED token can never be resurrected to unused;
  ///  - tombstones only need to win while they're careful about newer edits.
  static SyncMerge merge(
    List<Map<String, dynamic>> localRows,
    List<Map<String, dynamic>> remoteRecords,
  ) {
    final local = <String, Map<String, dynamic>>{
      for (final r in localRows) (r['id'] as String? ?? ''): r,
    };
    local.remove('');
    final remote = <String, Map<String, dynamic>>{
      for (final r in remoteRecords) (r['id'] as String? ?? ''): r,
    };
    remote.remove('');

    final toApply = <Map<String, dynamic>>[];
    final snapshot = <Map<String, dynamic>>[];

    // Remote-only records → materialize locally + snapshot.
    for (final entry in remote.entries) {
      final id = entry.key;
      final rec = entry.value;
      if (local.containsKey(id)) continue; // handled in the local loop
      snapshot.add(rec);
      toApply.add(recordToRow(rec));
    }

    for (final entry in local.entries) {
      final id = entry.key;
      final row = entry.value;
      final rec = remote[id];

      if (rec == null) {
        // Local-only: include in snapshot as-is (dirty or clean).
        snapshot.add(rowToRecord(row));
        continue;
      }

      final lUpd = (row['updatedAt'] as num?)?.toInt() ?? 0;
      final rUpd = (rec['updatedAt'] as num?)?.toInt() ?? 0;
      final lStatus = (row['status'] as num?)?.toInt() ?? 0;
      final rStatus = (rec['status'] as num?)?.toInt() ?? 0;
      final lUsed = lStatus == TokenStatus.redeemed.index;
      final rUsed = rStatus == TokenStatus.redeemed.index;

      final remoteWins = rUpd > lUpd;

      // ── Used-is-terminal: always keep the USED side's usage state.
      if (lUsed && !rUsed) {
        snapshot.add(rowToRecord(row));
        continue;
      }
      if (rUsed && !lUsed) {
        // Remote used wins even if local has newer updatedAt on an unused
        // side (rare: user editing on one phone while marking-used elsewhere).
        snapshot.add(rec);
        if (!_rowMatchesRecord(row, rec)) {
          toApply.add(recordToRow(rec));
        }
        continue;
      }

      if (!remoteWins) {
        // Local wins or tie → local persists; a tie means a local edit that
        // hasn't pushed yet stands (its newer state uploads anyway).
        snapshot.add(rowToRecord(row));
        continue;
      }

      // Remote strictly newer → apply.
      snapshot.add(rec);
      if (!_rowMatchesRecord(row, rec)) {
        toApply.add(recordToRow(rec));
      }
    }

    return SyncMerge(toApply, snapshot, toApply.isNotEmpty);
  }

  /// Full equality between a DB row and a JSON record on every synced field.
  /// Both sides go through [rowToRecord] so the comparison can never drift
  /// from the payload shape (missing keys, null vs absent, int vs double).
  /// Tombstone parity is included so a repeat merge is a no-op.
  static bool _rowMatchesRecord(Map<String, dynamic> row, Map rec) {
    final a = rowToRecord(row);
    final b = rowToRecord(Map<String, dynamic>.from(rec));
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      final other = b[entry.key];
      if (entry.key == 'deleted') {
        if (_asDeleted(entry.value) != _asDeleted(other)) return false;
      } else if (entry.value != other) {
        return false;
      }
    }
    return true;
  }

  static int nowMs() => DateTime.now().millisecondsSinceEpoch;

  /// Tolerates both the canonical JSON bool and an integer from older files.
  static bool _asDeleted(dynamic v) {
    if (v is bool) return v;
    if (v is num) return v.toInt() == 1;
    return false;
  }

  static int _weekOfYear(DateTime date) {
    final startOfYear = DateTime(date.year, 1, 1);
    final diff = date.difference(startOfYear).inDays;
    return (diff / 7).floor() + 1;
  }
}


/// ---- Payload helpers (byte level, engine agnostic) ---------------------

/// Stable fingerprint of a records snapshot: the same rows always hash to
/// the same code, so the engine can skip work when nothing changed and
/// never push content identical to what Drive already holds.
String recordsHashImpl(List<Map<String, dynamic>> records) {
  final canonical = const _CanonicalJsonEncoder().convert(records);
  return crypto.sha256.convert(utf8.encode(canonical)).toString();
}

String sha256Bytes(List<int> bytes) => crypto.sha256.convert(bytes).toString();

class _CanonicalJsonEncoder {
  const _CanonicalJsonEncoder();

  String convert(Object? value) {
    if (value is Map) {
      final keys = value.keys.map((k) => '$k').toList()..sort();
      return '{${[
        for (final k in keys)
          '${JsonEncoder().convert(k)}:${convert(value[k])}'
      ].join(',')}}';
    }
    if (value is List) {
      return '[${[for (final i in value) convert(i)].join(',')}]';
    }
    // SQLite stores REAL columns as doubles while JSON round-trips integral
    // values as ints (500.0 vs 500). Normalize so the same data always hashes
    // to the same code — otherwise the "nothing changed" fast path is dead.
    if (value is double && value.isFinite && value == value.roundToDouble()) {
      return value.toInt().toString();
    }
    return JsonEncoder().convert(value);
  }
}
/// Is this payload GZIP? (magic bytes 1F 8B)
bool isGzippedImpl(List<int> bytes) =>
    bytes.length >= 2 && bytes[0] == kGzipMagic0 && bytes[1] == kGzipMagic1;


