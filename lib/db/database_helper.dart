import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/token_record.dart';
import '../models/vehicle_owner.dart';
import '../services/renewal_service.dart';

/// DB v3 — sync-ready schema (see SYNC_PLAN.md):
///  - `updatedAt`  ms epoch, bumped on EVERY local write (merge discriminator)
///  - `deleted`    tombstone — rows are never physically removed, so deletions
///                 survive device-to-device merges
///  - `dirty`      1 = local change not yet pushed to Drive
/// Plus a `meta` key/value table for sync bookkeeping flags.
class DatabaseHelper {
  static final DatabaseHelper _instance = DatabaseHelper._internal();
  factory DatabaseHelper() => _instance;
  DatabaseHelper._internal();

  static Future<Database>? _databaseFuture;

  static final List<void Function(DatabaseHelper)> _writeListeners = [];
  static final List<void Function(DatabaseHelper)> _changeListeners = [];

  /// Register for post-write notifications (sync auto-push, live counters).
  /// Listeners may add other listeners while being notified, hence the copy.
  /// Fires only for LOCAL writes — never for rows merged down from Drive.
  static void addWriteListener(void Function(DatabaseHelper) l) {
    _writeListeners.add(l);
  }

  static void removeWriteListener(void Function(DatabaseHelper) l) {
    _writeListeners.remove(l);
  }

  /// Register for "visible data changed" notifications: local writes AND
  /// remote rows applied by sync. UI refresh and reminder re-scheduling use
  /// this; the sync engine itself must use [addWriteListener] to avoid
  /// kicking a fresh push every time it pulls.
  static void addChangeListener(void Function(DatabaseHelper) l) {
    _changeListeners.add(l);
  }

  static void removeChangeListener(void Function(DatabaseHelper) l) {
    _changeListeners.remove(l);
  }

  /// Memoized Future, not just the Database: two callers arriving before the
  /// first open completes used to race into two `openDatabase` calls.
  Future<Database> get database => _databaseFuture ??= _initDatabase();

  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'fueltoken_tracker.db');
    return openDatabase(
      path,
      version: 3,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE tokens (
        id TEXT PRIMARY KEY,
        tokenCode TEXT NOT NULL,
        vehicleNumber TEXT NOT NULL,
        vehicleType INTEGER NOT NULL,
        personName TEXT,
        mobileNumber TEXT,
        cnic TEXT,
        status INTEGER NOT NULL DEFAULT 0,
        dateReceived INTEGER NOT NULL,
        dateImported INTEGER NOT NULL,
        expiryDate INTEGER,
        subsidyAmount REAL,
        fuelLitres INTEGER,
        litresUsed INTEGER DEFAULT 0,
        originalMessage TEXT,
        notes TEXT,
        isPotentialDuplicate INTEGER DEFAULT 0,
        weekNumber INTEGER,
        weekYear INTEGER,
        redeemedAt INTEGER,
        updatedAt INTEGER NOT NULL DEFAULT 0,
        deleted INTEGER NOT NULL DEFAULT 0,
        dirty INTEGER NOT NULL DEFAULT 1
      )
    ''');

    await db.execute('''
      CREATE TABLE activity_log (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        tokenId TEXT,
        action TEXT NOT NULL,
        detail TEXT,
        timestamp INTEGER NOT NULL
      )
    ''');

    await db.execute(_metaTableSql);
  }

  static const String _metaTableSql = '''
      CREATE TABLE IF NOT EXISTS meta (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''';

  // ── INSERT ──────────────────────────────────────────────────────────────────
  Future<void> insertToken(TokenRecord token, {bool fromSync = false}) async {
    final db = await database;
    // Owner details are per-vehicle: a token imported from SMS/OCR carries no
    // name/CNIC, so inherit the freshest ones already recorded for this plate.
    final record = await _inheritVehicleOwner(token);
    final map = record.toMap();
    map['weekNumber'] = _weekOfYear(record.dateReceived);
    map['weekYear'] = record.dateReceived.year;
    // Sync bookkeeping: replaced old tombstones revive the record.
    map
      ..['updatedAt'] = DateTime.now().millisecondsSinceEpoch
      ..['dirty'] = fromSync ? 0 : 1
      ..['deleted'] = 0;
    await db.insert('tokens', map, conflictAlgorithm: ConflictAlgorithm.replace);
    await _log(db, record.id, 'ADDED', 'Token ${record.tokenCode} added');
    await _propagateVehicleOwner(db, record);
    if (!fromSync) _notify();
  }

  // ── UPDATE ──────────────────────────────────────────────────────────────────
  Future<void> updateToken(TokenRecord token, {bool fromSync = false}) async {
    final db = await database;
    final map = token.toMap();
    map['weekNumber'] = _weekOfYear(token.dateReceived);
    map['weekYear'] = token.dateReceived.year;
    if (!fromSync) {
      map
        ..['updatedAt'] = DateTime.now().millisecondsSinceEpoch
        ..['dirty'] = 1;
    }
    await db.update('tokens', map, where: 'id = ?', whereArgs: [token.id]);
    await _log(db, token.id, 'UPDATED', 'Token ${token.tokenCode} updated');
    // An owner name/CNIC added while editing this token fills the blanks on
    // the other tokens of the same vehicle.
    await _propagateVehicleOwner(db, token);
    if (!fromSync) _notify();
  }

  // ── DELETE → tombstone ──────────────────────────────────────────────────────
  /// Rows are flag-deleted, never removed: deletions then merge across
  /// devices, and History UNDO becomes trivial.
  Future<void> deleteToken(String id) async {
    final db = await database;
    await _tombstone(db, [id]);
    await _log(db, id, 'DELETED', 'Token deleted');
    _notify();
  }

  // ── BULK DELETE (history multi-select) ──────────────────────────────────────
  Future<void> deleteTokens(List<String> ids) async {
    if (ids.isEmpty) return;
    final db = await database;
    await _tombstone(db, ids);
    await _log(db, ids.join(','), 'BULK_DELETED', '${ids.length} tokens deleted');
    _notify();
  }

  Future<void> _tombstone(Database db, List<String> ids) async {
    final placeholders = List.filled(ids.length, '?').join(',');
    await db.update(
      'tokens',
      {
        'deleted': 1,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
        'dirty': 1,
      },
      where: 'id IN ($placeholders)',
      whereArgs: ids,
    );
  }

  /// History UNDO: flips tombstones back on.
  Future<void> restoreTokens(List<String> ids) async {
    if (ids.isEmpty) return;
    final db = await database;
    final placeholders = List.filled(ids.length, '?').join(',');
    await db.update(
      'tokens',
      {
        'deleted': 0,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
        'dirty': 1,
      },
      where: 'id IN ($placeholders)',
      whereArgs: ids,
    );
    await _log(db, ids.join(','), 'RESTORED', '${ids.length} tokens restored');
    _notify();
  }

  // ── APPLY REMOTE (from Drive) ───────────────────────────────────────────────
  /// Wins decided by the merger. Never fires WRITE listeners and never marks
  /// dirty — this IS the sync pushback, not a user edit. It does fire CHANGE
  /// listeners so open screens refresh and reminders are re-scheduled.
  Future<void> applyRemoteRecords(List<Map<String, dynamic>> rows) async {
    if (rows.isEmpty) return;
    final db = await database;
    final batch = db.batch();
    for (final source in rows) {
      // sqflite BATCH inserts reject null values — strip them; absent
      // nullable columns fall back to NULL on insert.
      final row = Map<String, dynamic>.from(source)
        ..removeWhere((_, v) => v == null);
      batch.insert('tokens', row, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
    // Rows changed underneath the UI: refresh lists/cards. Does NOT fire
    // write listeners, so this can never trigger another push.
    _notifyChange();
  }

  // ── READ: all tokens ────────────────────────────────────────────────────────
  Future<List<TokenRecord>> getAllTokens() async {
    final db = await database;
    final maps = await db.query(
      'tokens',
      where: 'deleted = 0',
      orderBy: 'dateReceived DESC',
    );
    return maps.map(TokenRecord.fromMap).toList();
  }

  // ── READ: active tokens for this week ───────────────────────────────────────
  Future<List<TokenRecord>> getThisWeekActive() async {
    final db = await database;
    final now = DateTime.now();
    final week = _weekOfYear(now);
    final year = now.year;
    final maps = await db.query(
      'tokens',
      where: 'weekYear = ? AND weekNumber = ? AND status = ? AND deleted = 0',
      whereArgs: [year, week, TokenStatus.active.index],
      orderBy: 'dateReceived DESC',
    );
    return maps.map(TokenRecord.fromMap).toList();
  }

  // ── READ: single token by id ────────────────────────────────────────────────
  Future<TokenRecord?> getTokenById(String id) async {
    final db = await database;
    final maps = await db.query(
      'tokens',
      where: 'id = ? AND deleted = 0',
      whereArgs: [id],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return TokenRecord.fromMap(maps.first);
  }

  // ── READ: active tokens (any week) ─────────────────────────────────────────
  Future<List<TokenRecord>> getActiveTokens() async {
    final db = await database;
    final maps = await db.query(
      'tokens',
      where: 'status = ? AND deleted = 0',
      whereArgs: [TokenStatus.active.index],
      orderBy: 'dateReceived DESC',
    );
    return maps.map(TokenRecord.fromMap).toList();
  }

  // ── READ: tokens by vehicle ─────────────────────────────────────────────────
  Future<List<TokenRecord>> getTokensByVehicle(String vehicleNumber) async {
    final db = await database;
    final maps = await db.query(
      'tokens',
      where: 'vehicleNumber = ? AND deleted = 0',
      whereArgs: [vehicleNumber.toUpperCase()],
      orderBy: 'dateReceived DESC',
    );
    return maps.map(TokenRecord.fromMap).toList();
  }

  // ── READ: search ────────────────────────────────────────────────────────────
  Future<List<TokenRecord>> search(String query) async {
    final db = await database;
    final q = '%$query%';
    final maps = await db.query(
      'tokens',
      where:
          'deleted = 0 AND (tokenCode LIKE ? OR vehicleNumber LIKE ? OR personName LIKE ? OR mobileNumber LIKE ?)',
      whereArgs: [q, q, q, q],
      orderBy: 'dateReceived DESC',
    );
    return maps.map(TokenRecord.fromMap).toList();
  }

  // ── READ: stats ─────────────────────────────────────────────────────────────
  Future<Map<String, int>> getStats() async {
    final db = await database;
    final now = DateTime.now();
    final week = _weekOfYear(now);
    final year = now.year;

    final nowMs = DateTime.now().millisecondsSinceEpoch;

    final total = Sqflite.firstIntValue(await db.rawQuery(
            'SELECT COUNT(*) FROM tokens WHERE deleted = 0')) ??
        0;
    // "Active" = active rows whose expiry hasn't passed yet
    final active = Sqflite.firstIntValue(await db.rawQuery(
      'SELECT COUNT(*) FROM tokens WHERE status = ${TokenStatus.active.index} '
      'AND deleted = 0 AND (expiryDate IS NULL OR expiryDate > ?)',
      [nowMs],
    )) ?? 0;
    final redeemed = Sqflite.firstIntValue(await db.rawQuery(
        'SELECT COUNT(*) FROM tokens WHERE status = ${TokenStatus.redeemed.index} AND deleted = 0')) ??
        0;
    final thisWeek = Sqflite.firstIntValue(await db.rawQuery(
        'SELECT COUNT(*) FROM tokens WHERE weekYear = $year AND weekNumber = $week AND deleted = 0')) ??
        0;

    return {
      'total': total,
      'active': active,
      'redeemed': redeemed,
      'thisWeek': thisWeek,
    };
  }

  // ── READ: activity log ──────────────────────────────────────────────────────
  Future<List<Map<String, dynamic>>> getActivityLog({int limit = 50}) async {
    final db = await database;
    return db.query('activity_log', orderBy: 'timestamp DESC', limit: limit);
  }

  // ── MARK REDEEMED ───────────────────────────────────────────────────────────
  Future<void> markRedeemed(String id) async {
    final db = await database;
    await db.update(
      'tokens',
      {
        'status': TokenStatus.redeemed.index,
        'redeemedAt': DateTime.now().millisecondsSinceEpoch,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
        'dirty': 1,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    await _log(db, id, 'REDEEMED', 'Token marked as redeemed at pump');
    _notify();
  }

  // ── READ: used (redeemed) tokens, newest-used first ────────────────────────
  Future<List<TokenRecord>> getRedeemedTokens() async {
    final db = await database;
    final maps = await db.query(
      'tokens',
      where: 'status = ? AND deleted = 0',
      whereArgs: [TokenStatus.redeemed.index],
      orderBy: 'redeemedAt DESC',
    );
    return maps.map(TokenRecord.fromMap).toList();
  }

  // ── DUPLICATE CHECK ─────────────────────────────────────────────────────────
  Future<bool> tokenCodeExists(String code, {String? excludeId}) async {
    final db = await database;
    final maps = await db.query(
      'tokens',
      columns: ['id'],
      where: excludeId != null
          ? 'tokenCode = ? AND id != ? AND deleted = 0'
          : 'tokenCode = ? AND deleted = 0',
      whereArgs: excludeId != null ? [code, excludeId] : [code],
      limit: 1,
    );
    return maps.isNotEmpty;
  }

  // ── OWNER DETAILS (per vehicle, shared by all of its tokens) ───────────────

  /// SQL expression matching a plate regardless of case, spaces and dashes,
  /// mirroring [RenewalService.normalizeVehicle].
  static const String _vehicleKeySql =
      "UPPER(REPLACE(REPLACE(TRIM(vehicleNumber), '-', ''), ' ', ''))";

  /// Freshest non-empty owner name / CNIC ever recorded for [vehicleNumber].
  /// The fields are looked up independently, so a name from one token and a
  /// CNIC from another still combine. Returns null when nothing is known.
  Future<VehicleOwner?> vehicleOwnerFor(String vehicleNumber,
      {String? excludeId}) async {
    final key = RenewalService.normalizeVehicle(vehicleNumber);
    if (key.isEmpty) return null;
    final db = await database;
    final where = StringBuffer('deleted = 0 AND $_vehicleKeySql = ?');
    final args = <Object?>[key];
    if (excludeId != null) {
      where.write(' AND id != ?');
      args.add(excludeId);
    }
    final maps = await db.query(
      'tokens',
      columns: ['personName', 'cnic'],
      where: where.toString(),
      whereArgs: args,
      orderBy: 'dateImported DESC, dateReceived DESC',
    );
    String? name;
    String? cnic;
    for (final m in maps) {
      name ??= VehicleOwner.clean(m['personName']);
      cnic ??= VehicleOwner.clean(m['cnic']);
      if (name != null && cnic != null) break;
    }
    if (name == null && cnic == null) return null;
    return VehicleOwner(personName: name, cnic: cnic);
  }

  /// Fills a new token's blank owner fields from the same vehicle's history.
  Future<TokenRecord> _inheritVehicleOwner(TokenRecord token) async {
    final hasName = VehicleOwner.clean(token.personName) != null;
    final hasCnic = VehicleOwner.clean(token.cnic) != null;
    if (hasName && hasCnic) return token;
    try {
      final owner =
          await vehicleOwnerFor(token.vehicleNumber, excludeId: token.id);
      if (owner == null) return token;
      return token.copyWith(
        personName: hasName ? null : owner.personName,
        cnic: hasCnic ? null : owner.cnic,
      );
    } catch (_) {
      // Owner enrichment is a convenience — never fail the save for it.
      return token;
    }
  }

  /// Copies non-empty owner details onto sibling tokens of the same vehicle
  /// that are missing them. Existing values are never overwritten. Only rows
  /// that actually gain something are touched, and their `updatedAt`/`dirty`
  /// are bumped so the fill also reaches other devices through sync.
  Future<void> _propagateVehicleOwner(Database db, TokenRecord token) async {
    final name = VehicleOwner.clean(token.personName);
    final cnic = VehicleOwner.clean(token.cnic);
    if (name == null && cnic == null) return;
    final key = RenewalService.normalizeVehicle(token.vehicleNumber);
    if (key.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;

    Future<void> fill(String column, String value) => db.rawUpdate(
          'UPDATE tokens SET $column = ?, updatedAt = ?, dirty = 1 '
          'WHERE deleted = 0 AND $_vehicleKeySql = ? AND id != ? '
          "AND ($column IS NULL OR TRIM($column) = '')",
          [value, now, key, token.id],
        );

    if (name != null) await fill('personName', name);
    if (cnic != null) await fill('cnic', cnic);
  }

  // ── SYNC HELPERS ────────────────────────────────────────────────────────────
  Future<int> tokenCount() async {
    final db = await database;
    return Sqflite.firstIntValue(
            await db.rawQuery('SELECT COUNT(*) FROM tokens WHERE deleted = 0')) ??
        0;
  }

  /// Every row INCLUDING tombstones — the sync engine's full view.
  Future<List<Map<String, dynamic>>> getSyncSnapshot() async {
    final db = await database;
    return db.query('tokens');
  }

  // ── META (key/value bookkeeping) ────────────────────────────────────────────
  Future<void> setMeta(String key, String value) async {
    final db = await database;
    await db.insert(
      'meta',
      {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<String?> getMeta(String key) async {
    final db = await database;
    final maps = await db.query('meta',
        where: 'key = ?', whereArgs: [key], limit: 1);
    if (maps.isEmpty) return null;
    return maps.first['value'] as String?;
  }

  // ── HELPERS ─────────────────────────────────────────────────────────────────
  int _weekOfYear(DateTime date) {
    final startOfYear = DateTime(date.year, 1, 1);
    final diff = date.difference(startOfYear).inDays;
    return (diff / 7).floor() + 1;
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    // v2: track exactly WHEN a token was used at the pump.
    if (oldVersion < 2) {
      await db.execute('ALTER TABLE tokens ADD COLUMN redeemedAt INTEGER');
      // Backfill from the audit log where possible.
      await db.execute('''
        UPDATE tokens
        SET redeemedAt = (
          SELECT MIN(timestamp) FROM activity_log
          WHERE action = 'REDEEMED' AND activity_log.tokenId = tokens.id
        )
        WHERE status = ? AND redeemedAt IS NULL
      ''', [TokenStatus.redeemed.index]);
    }

    // v3: sync-ready columns + meta table.
    if (oldVersion < 3) {
      await db.execute(
          'ALTER TABLE tokens ADD COLUMN updatedAt INTEGER NOT NULL DEFAULT 0');
      await db.execute(
          'ALTER TABLE tokens ADD COLUMN deleted INTEGER NOT NULL DEFAULT 0');
      await db.execute(
          'ALTER TABLE tokens ADD COLUMN dirty INTEGER NOT NULL DEFAULT 1');
      await db.execute(_metaTableSql);
      // Existing rows: monotonically anchored to their last known activity,
      // so the first sync treats local as authoritative-but-not-greater-than
      // anything pushed after.
      await db.execute('''
        UPDATE tokens SET updatedAt = COALESCE(redeemedAt, dateImported, 0)
      ''');
    }
  }

  Future<void> _log(Database db, String tokenId, String action, String detail) async {
    await db.insert('activity_log', {
      'tokenId': tokenId,
      'action': action,
      'detail': detail,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
  }

  void _notify() {
    _notifyListeners(_writeListeners);
    _notifyListeners(_changeListeners);
  }

  void _notifyChange() => _notifyListeners(_changeListeners);

  void _notifyListeners(List<void Function(DatabaseHelper)> listeners) {
    for (final l in List.of(listeners)) {
      try {
        l(this);
      } catch (_) {
        // A broken listener must never fail the write that triggered it.
      }
    }
  }
}
