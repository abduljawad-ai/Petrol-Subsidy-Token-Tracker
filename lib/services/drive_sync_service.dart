import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:http/http.dart' as http;

import '../db/database_helper.dart';
import 'backup_codec.dart';
import 'sync_config.dart';

/// Live sync UI-state (never blocks local work — errors land here quietly).
class SyncState {
  final bool signedIn;
  final String? email;
  final DateTime? lastSyncedAt;
  final bool busy;
  final String? error;
  final bool setupNeeded;

  const SyncState({
    this.signedIn = false,
    this.email,
    this.lastSyncedAt,
    this.busy = false,
    this.error,
    this.setupNeeded = false,
  });

  SyncState copyWith({
    bool? signedIn,
    String? email,
    DateTime? lastSyncedAt,
    bool? busy,
    String? error,
    bool? setupNeeded,
    bool clearEmail = false,
    bool clearError = false,
  }) =>
      SyncState(
        signedIn: signedIn ?? this.signedIn,
        email: clearEmail ? null : (email ?? this.email),
        lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
        busy: busy ?? this.busy,
        error: clearError ? null : (error ?? this.error),
        setupNeeded: setupNeeded ?? this.setupNeeded,
      );
}

/// Google Drive (appDataFolder) backup & sync engine.
///
/// Rules:
///  - Session is PERMANENT until user explicitly signs out via Settings.
///  - App open NEVER shows login or account picker dialogs.
///  - Background sync (open & on-write) runs completely silently with zero UI.
///  - Local DB is always authoritative; sync never blocks local edits.
class DriveSyncService {
  DriveSyncService._();
  static final DriveSyncService instance = DriveSyncService._();

  static const String _metaLastSynced = 'lastSyncedAt';
  static const String _driveBase = 'https://www.googleapis.com/drive/v3';
  static const String _driveUploadBase =
      'https://www.googleapis.com/upload/drive/v3';
  static const Duration _httpTimeout = Duration(seconds: 30);
  static const Duration _minRetry = Duration(seconds: 90);
  static const Duration _maxRetry = Duration(minutes: 15);

  final ValueNotifier<SyncState> state = ValueNotifier(const SyncState());

  final DatabaseHelper _db = DatabaseHelper();
  GoogleSignInAccount? _account;
  Timer? _debounce;
  Timer? _silentRetry;
  bool _gestureBusy = false;
  bool _syncing = false;
  bool _queued = false;
  Future<void>? _initFuture;
  bool _gsiInitialized = false;
  Duration _retryDelay = _minRetry;

  /// Every Drive/HTTP call gets a hard deadline. Without one a stalled socket
  /// keeps `_syncing` true forever and every later sync is silently dropped.
  Future<http.Response> _send(Future<http.Response> request) =>
      request.timeout(_httpTimeout);

  Future<void> _ensureGsiInitialized() async {
    if (_gsiInitialized) return;
    await GoogleSignIn.instance.initialize(serverClientId: kSyncWebClientId);
    _gsiInitialized = true;
  }

  // ── BOOT ────────────────────────────────────────────────────────────────────
  /// One-time app boot initialization.
  /// Instantly restores the saved session from DB so Settings & UI show
  /// "Backup is on" immediately with NO popups, NO delays, and NO timers.
  ///
  /// The in-flight Future is memoized: callers that arrive while the first
  /// run is still reading meta must wait, not sail past a half-restored
  /// session (which used to show the "back up?" intro to signed-in users).
  Future<void> init() async {
    final existing = _initFuture;
    if (existing != null) return existing;
    final next = _initOnce();
    _initFuture = next;
    try {
      await next;
    } catch (_) {
      // Allow a later attempt (e.g. DB temporarily locked at boot).
      if (identical(_initFuture, next)) _initFuture = null;
      rethrow;
    }
  }

  Future<void> _initOnce() async {
    DatabaseHelper.addWriteListener((_) => instance.kick());
    await _reloadLastSynced();

    // Instant session restore from local durable storage:
    // Closing and reopening NEVER resets login status!
    final savedEmail = await _db.getMeta('signed_email');
    final isSignedOut = await _db.getMeta('signed_out') == '1';

    if (savedEmail != null && savedEmail.isNotEmpty && !isSignedOut) {
      state.value = state.value.copyWith(
        signedIn: true,
        email: savedEmail,
        setupNeeded: false,
        clearError: true,
      );

      // Quiet startup catch-up sync 2 seconds after open (NO UI)
      Timer(const Duration(seconds: 2), () {
        syncNow('startup');
      });
    }

    if (kSyncWebClientId.isEmpty) {
      state.value = state.value.copyWith(
        setupNeeded: true,
        error: 'Backup is being set up. It will be available after the next update.',
      );
    }
  }

  Future<void> _reloadLastSynced() async {
    final v = await _db.getMeta(_metaLastSynced);
    final ms = int.tryParse(v ?? '');
    if (ms != null) {
      state.value =
          state.value.copyWith(lastSyncedAt: DateTime.fromMillisecondsSinceEpoch(ms));
    }
  }

  // ── ACCESS TOKEN (Zero-UI silent retrieval) ─────────────────────────────────
  /// Obtains an OAuth2 access token for Google Drive.
  /// If [allowUi] is false, it asks Google Play Services silently without
  /// showing ANY UI. If the user already authorized the app, Play Services
  /// returns a valid or refreshed token with 0 dialogs.
  Future<String?> _getAccessToken({required bool allowUi}) async {
    final email = await _db.getMeta('signed_email');
    final isSignedOut = await _db.getMeta('signed_out') == '1';
    if (email == null || email.isEmpty || isSignedOut) return null;

    try {
      await _ensureGsiInitialized();
      final tokens = await GoogleSignInPlatform.instance
          .clientAuthorizationTokensForScopes(
        ClientAuthorizationTokensForScopesParameters(
          request: AuthorizationRequestDetails(
            scopes: kDriveScopes,
            userId: null,
            email: email,
            promptIfUnauthorized: allowUi,
          ),
        ),
      )
          .timeout(const Duration(seconds: 20));
      return tokens?.accessToken;
    } catch (_) {
      return null;
    }
  }

  // ── SIGN IN (Explicit user tap) ─────────────────────────────────────────────
  /// Interactive sign-in triggered ONLY when user explicitly taps "Continue with Google".
  /// Shows the Google account chooser, requests Drive authorization, and saves
  /// the session permanently.
  Future<GoogleSignInAccount?> signInFromUserGesture() async {
    if (kSyncWebClientId.isEmpty) {
      state.value = state.value.copyWith(
        setupNeeded: true,
        error:
            'Backup is being set up. It will be available after the next update.',
      );
      return null;
    }
    if (_gestureBusy) return _account;
    _gestureBusy = true;
    try {
      await init();
      await _ensureGsiInitialized();

      // Official Google sign-in account chooser
      final account = await GoogleSignIn.instance.authenticate();

      // Request Drive scope authorization
      final authTokens = await GoogleSignInPlatform.instance
          .clientAuthorizationTokensForScopes(
        ClientAuthorizationTokensForScopesParameters(
          request: AuthorizationRequestDetails(
            scopes: kDriveScopes,
            userId: null,
            email: account.email,
            promptIfUnauthorized: true,
          ),
        ),
      );

      // Save session PERMANENTLY
      await _db.setMeta('signed_email', account.email);
      await _db.setMeta('signed_in', '1');
      await _db.setMeta('signed_out', '0');
      await _db.setMeta('signed_once', '1');
      await _db.setMeta('sync_intro_done', '1');
      await _db.setMeta('sync_declined', '0');

      _account = account;

      state.value = state.value.copyWith(
        signedIn: true,
        email: account.email,
        clearError: true,
        setupNeeded: false,
      );

      if (authTokens?.accessToken == null) {
        state.value = state.value.copyWith(
          error: 'Drive permission not granted — tap "Sync now" to authorize.',
        );
        return account;
      }

      await syncNow('signin');
      return account;
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) {
        state.value = state.value.copyWith(
          error: 'Sign-in was closed. Tap "Continue with Google" when ready.',
        );
        return null;
      }
      state.value = state.value.copyWith(
        error: 'Sign-in did not complete: ${e.description ?? e.code}',
      );
      return null;
    } catch (e) {
      state.value = state.value.copyWith(
        error: 'Sign-in did not complete. Please tap "Continue with Google" again.',
      );
      return null;
    } finally {
      _gestureBusy = false;
    }
  }

  // ── SIGN OUT ────────────────────────────────────────────────────────────────
  /// Explicitly severs the session. Only after this does the app prompt for login again.
  Future<void> signOut() async {
    await init();
    // Stop every queued/pending background pass: a retry that wakes up after
    // sign-out would otherwise try to re-authenticate silently.
    _silentRetry?.cancel();
    _silentRetry = null;
    _debounce?.cancel();
    _debounce = null;
    _retryDelay = _minRetry;
    try {
      await _ensureGsiInitialized();
      await GoogleSignIn.instance.signOut();
    } catch (_) {}
    _account = null;
    await _db.setMeta('signed_out', '1');
    await _db.setMeta('signed_in', '0');
    await _db.setMeta('signed_email', '');
    state.value = state.value.copyWith(
      signedIn: false,
      clearEmail: true,
      clearError: true,
    );
  }

  // ── AUTO-SYNC HOOK ──────────────────────────────────────────────────────────
  /// Fired by DatabaseHelper.onWrite after every add/use/delete/edit.
  /// Debounces short bursts into one sync.
  void kick() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 3), () {
      if (state.value.signedIn) {
        unawaited(syncNow('auto'));
      }
    });
  }

  // ── THE ENGINE: pull → merge → push ────────────────────────────────────────
  Future<void> syncNow(String reason) async {
    final email = await _db.getMeta('signed_email');
    final isSignedOut = await _db.getMeta('signed_out') == '1';
    if (email == null || email.isEmpty || isSignedOut) {
      if (reason == 'manual' || reason == 'signin' || reason == 'restore') {
        final acc = await signInFromUserGesture();
        if (acc == null) return;
      }
      return;
    }

    if (_syncing) {
      _queued = true;
      return;
    }
    _syncing = true;
    state.value = state.value.copyWith(busy: true, clearError: true);

    try {
      final allowUi = (reason == 'manual' || reason == 'signin' || reason == 'restore');
      final accessToken = await _getAccessToken(allowUi: allowUi);
      if (accessToken == null) {
        if (!allowUi) {
          // Background pass: stay completely quiet
          state.value = state.value.copyWith(busy: false, clearError: true);
          _scheduleSilentRetry();
          return;
        }
        throw 'Drive permission needed — tap "Sync now" to authorize.';
      }

      final headers = {'Authorization': 'Bearer $accessToken'};
      final client = http.Client();
      try {
        // 1) FIND the backup file
        final listUri = Uri.parse('$_driveBase/files'
            '?fields=files(id,name,modifiedTime)'
            '&q=${Uri.encodeQueryComponent(
          "(name = '$kBackupFileGzName' or name = '$kBackupFileName') and trashed = false",
        )}'
            '&spaces=appDataFolder');
        final listRes = await _send(client.get(listUri, headers: headers));
        if (listRes.statusCode != 200) {
          throw 'Drive error ${listRes.statusCode}: ${SyncText.driveError(listRes.body)}';
        }
        final files = (jsonDecode(listRes.body)['files'] as List?) ?? const [];
        // Prefer the compressed file when a legacy plain-JSON file still
        // exists in the same folder (older installs uploaded both).
        Map<String, dynamic>? fileRow;
        Map<String, dynamic>? legacyRow;
        for (final f in files.whereType<Map>()) {
          final row = Map<String, dynamic>.from(f);
          if (row['name'] == kBackupFileGzName) {
            fileRow = row;
          } else {
            legacyRow ??= row;
          }
        }
        fileRow ??= legacyRow;
        final String? fileId = fileRow?['id'] as String?;
        final String? remoteMtime = fileRow?['modifiedTime'] as String?;
        final seenMtime = await _db.getMeta('drive_mtime_seen');
        final pushedHash = await _db.getMeta('drive_push_hash');

        final localRows = await _db.getSyncSnapshot();
        // Normalized through rowToRecord inside recordsHash, so this equals
        // the hash of the pushed snapshot for the same content.
        final localHash = BackupCodec.recordsHash(localRows);
        final remoteUnchanged = remoteMtime != null && remoteMtime == seenMtime;

        // Skip unnecessary download/upload if nothing changed
        if (remoteUnchanged && pushedHash == localHash) {
          final now = DateTime.now();
          await _db.setMeta(
              _metaLastSynced, now.millisecondsSinceEpoch.toString());
          state.value = state.value.copyWith(
            busy: false,
            lastSyncedAt: now,
            clearError: true,
          );
          return;
        }

        // 2) DOWNLOAD remote backup if changed
        List<Map<String, dynamic>> remoteRecords = const [];
        String remoteHash = '';
        bool remoteChanged = false;
        if (fileId != null && !remoteUnchanged) {
          final dl = await _send(client.get(
            Uri.parse('$_driveBase/files/$fileId?alt=media'),
            headers: headers,
          ));
          if (dl.statusCode != 200) {
            throw 'Drive download failed ${dl.statusCode}: ${SyncText.driveError(dl.body)}';
          }
          final payload = dl.bodyBytes;
          if (payload.isEmpty ||
              utf8.decode(payload, allowMalformed: true).trim().isEmpty) {
            remoteHash = BackupCodec.recordsHash(const []);
            remoteChanged = true;
          } else {
            final decodedJson = BackupCodec.isGzipped(payload)
                ? utf8.decode(gzip.decode(payload))
                : utf8.decode(payload);
            if (decodedJson.trim().isNotEmpty) {
              remoteRecords = BackupCodec.parseEnvelope(jsonDecode(decodedJson));
              remoteHash = BackupCodec.recordsHash(remoteRecords);
              remoteChanged = true;
            }
          }
        }

        // 3) MERGE remote winners into local DB
        final merge = BackupCodec.merge(localRows, remoteRecords);
        if (merge.toApply.isNotEmpty) {
          await _db.applyRemoteRecords(merge.toApply);
        }

        // 4) PUSH to Drive if needed
        final snapshotHash = BackupCodec.recordsHash(merge.snapshot);
        final pushNeeded = snapshotHash != remoteHash;
        if (pushNeeded) {
          final envelope = BackupCodec.buildEnvelope(
            records: merge.snapshot,
            deviceName: Platform.localHostname,
            lastSyncedAtMs: DateTime.now().millisecondsSinceEpoch,
          );
          final gzBytes = gzip.encode(utf8.encode(jsonEncode(envelope)));
          final gzHeaders = {
            ...headers,
            'Content-Type': 'application/gzip',
            'Content-Encoding': 'gzip',
          };

          // Patch the existing .gz file, or create it (first backup, or the
          // cloud only has the legacy plain-JSON file).
          var targetId =
              fileRow?['name'] == kBackupFileGzName ? fileId : null;
          if (targetId == null) {
            final create = await _send(client.post(
              Uri.parse('$_driveBase/files?fields=id'),
              headers: {...headers, 'Content-Type': 'application/json'},
              body: jsonEncode({
                'name': kBackupFileGzName,
                'parents': ['appDataFolder'],
              }),
            ));
            if (create.statusCode != 200 && create.statusCode != 201) {
              throw 'Drive create failed ${create.statusCode}: ${SyncText.driveError(create.body)}';
            }
            targetId = (jsonDecode(create.body)['id'] ?? '') as String;
            if (targetId.isEmpty) throw 'Drive create returned no file id.';
          }

          final put = await _send(client.patch(
            Uri.parse('$_driveUploadBase/files/$targetId?uploadType=media'),
            headers: gzHeaders,
            body: gzBytes,
          ));
          if (put.statusCode != 200) {
            throw 'Drive upload failed ${put.statusCode}: ${SyncText.driveError(put.body)}';
          }
          final mt = (jsonDecode(put.body)['modifiedTime'] ?? '') as String;
          if (mt.isNotEmpty) {
            await _db.setMeta('drive_mtime_seen', mt);
          }
          await _db.setMeta('drive_push_hash', snapshotHash);

          // The legacy plain file is superseded: trash it (best effort) so a
          // fresh install cannot restore a stale copy.
          final legacyId = legacyRow?['id'] as String?;
          if (legacyId != null && legacyId.isNotEmpty && legacyId != targetId) {
            try {
              await _send(client.patch(
                Uri.parse('$_driveBase/files/$legacyId'),
                headers: {...headers, 'Content-Type': 'application/json'},
                body: jsonEncode({'trashed': true}),
              ));
            } catch (_) {
              // Cleanup only — the backup itself already succeeded.
            }
          }
        } else if (remoteChanged) {
          // Content is identical: remember the hash so the next pass can take
          // the no-op fast path instead of downloading the file again.
          await _db.setMeta('drive_mtime_seen', remoteMtime ?? '');
          await _db.setMeta('drive_push_hash', snapshotHash);
        }

        // 5) Bookkeeping
        final now = DateTime.now();
        _retryDelay = _minRetry;
        await _db.setMeta(_metaLastSynced, now.millisecondsSinceEpoch.toString());
        state.value = state.value.copyWith(
          busy: false,
          lastSyncedAt: now,
          clearError: true,
        );
      } finally {
        client.close();
      }
    } catch (e) {
      if (reason == 'startup' || reason == 'auto') {
        state.value = state.value.copyWith(busy: false, clearError: true);
        _scheduleSilentRetry();
      } else {
        state.value =
            state.value.copyWith(busy: false, error: SyncText.short(e));
      }
    } finally {
      _syncing = false;
      if (_queued) {
        _queued = false;
        kick();
      }
    }
  }

  void _scheduleSilentRetry() {
    _silentRetry?.cancel();
    final delay = _retryDelay;
    // Exponential backoff: a phone offline for hours must not wake every 90s
    // forever. Reset to the floor after the next successful sync.
    final next = _retryDelay * 2;
    _retryDelay = next > _maxRetry ? _maxRetry : next;
    _silentRetry = Timer(delay, () {
      if (state.value.signedIn) {
        unawaited(syncNow('auto'));
      }
    });
  }

  /// Quick remote peek for restore prompt: (live count, modified time)
  Future<(int, DateTime)?> peekCloudBackup() async {
    final token = await _getAccessToken(allowUi: false);
    if (token == null) return null;
    http.Client? client;
    try {
      client = http.Client();
      final headers = {'Authorization': 'Bearer $token'};
      final listUri = Uri.parse('$_driveBase/files'
          '?fields=files(id,modifiedTime)'
          '&q=${Uri.encodeQueryComponent(
        "(name = '$kBackupFileGzName' or name = '$kBackupFileName') and trashed = false",
      )}'
          '&spaces=appDataFolder');
      final res = await _send(client.get(listUri, headers: headers));
      if (res.statusCode != 200) return null;
      final files = (jsonDecode(res.body)['files'] as List?) ?? const [];
      final rows = files.whereType<Map>().toList();
      if (rows.isEmpty) return null;
      // Same preference as syncNow: the compressed file is authoritative.
      final first = rows.firstWhere(
        (f) => f['name'] == kBackupFileGzName,
        orElse: () => rows.first,
      );
      final modified =
          DateTime.tryParse(first['modifiedTime'] as String? ?? '');
      final dl = await _send(client.get(
        Uri.parse('$_driveBase/files/${first['id']}?alt=media'),
        headers: headers,
      ));
      final payload = dl.bodyBytes;
      if (payload.isEmpty) return null;
      final decodedJson = BackupCodec.isGzipped(payload)
          ? utf8.decode(gzip.decode(payload))
          : utf8.decode(payload);
      if (decodedJson.trim().isEmpty) return null;
      final records = BackupCodec.parseEnvelope(jsonDecode(decodedJson));
      final live =
          records.where((r) => r['deleted'] != true && r['deleted'] != 1).length;
      if (live == 0) return null;
      return (live, modified ?? DateTime.now());
    } catch (_) {
      return null;
    } finally {
      client?.close();
    }
  }
}

/// Small formatting helpers used by the sync UI + service errors.
class SyncText {
  SyncText._();

  static String short(Object e) {
    final s = e.toString().replaceAll('\n', ' ');
    return s.length > 180 ? '${s.substring(0, 180)}…' : s;
  }

  static String driveError(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['error'] is Map) {
        final err = decoded['error'] as Map;
        return err['message']?.toString() ??
            err['status']?.toString() ??
            'unknown';
      }
    } catch (_) {}
    return body.length > 60 ? body.substring(0, 60) : body;
  }

  /// "Synced 16:47" / "3h ago" style line for the Settings card.
  static String lastSyncedLabel(DateTime? at) {
    if (at == null) return 'Never';
    return '${at.day}-${_month(at.month)} ${_hhmm(at)}';
  }

  static String _month(int m) =>
      const ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
          'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][m - 1];

  static String _hhmm(DateTime t) {
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    final ap = t.hour < 12 ? 'am' : 'pm';
    return '$h:${t.minute.toString().padLeft(2, '0')}$ap';
  }
}
