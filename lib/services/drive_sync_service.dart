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
    bool clearError = false,
  }) =>
      SyncState(
        signedIn: signedIn ?? this.signedIn,
        email: email ?? this.email,
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

  final ValueNotifier<SyncState> state = ValueNotifier(const SyncState());

  final DatabaseHelper _db = DatabaseHelper();
  GoogleSignInAccount? _account;
  Timer? _debounce;
  Timer? _silentRetry;
  bool _gestureBusy = false;
  bool _syncing = false;
  bool _queued = false;
  bool _initialized = false;
  bool _gsiInitialized = false;

  Future<void> _ensureGsiInitialized() async {
    if (_gsiInitialized) return;
    await GoogleSignIn.instance.initialize(serverClientId: kSyncWebClientId);
    _gsiInitialized = true;
  }

  // ── BOOT ────────────────────────────────────────────────────────────────────
  /// One-time app boot initialization.
  /// Instantly restores the saved session from DB so Settings & UI show
  /// "Backup is on" immediately with NO popups, NO delays, and NO timers.
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

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
      );
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
      if (!_initialized) await init();
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
    if (!_initialized) await init();
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
      email: null,
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
        final listRes = await client.get(listUri, headers: headers);
        if (listRes.statusCode != 200) {
          throw 'Drive error ${listRes.statusCode}: ${SyncText.driveError(listRes.body)}';
        }
        final files = (jsonDecode(listRes.body)['files'] as List?) ?? const [];
        Map<String, dynamic>? fileRow;
        for (final f in files) {
          final row = f as Map<String, dynamic>;
          if (row['name'] == kBackupFileGzName) {
            fileRow = row;
            break;
          }
          fileRow ??= row;
        }
        final String? fileId = fileRow?['id'] as String?;
        final String? remoteMtime = fileRow?['modifiedTime'] as String?;
        final seenMtime = await _db.getMeta('drive_mtime_seen');
        final pushedHash = await _db.getMeta('drive_push_hash');

        final localRows = await _db.getSyncSnapshot();
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
          final dl = await client.get(
            Uri.parse('$_driveBase/files/$fileId?alt=media'),
            headers: headers,
          );
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
          final useGzName = (fileRow == null) ||
              (fileRow['name'] == kBackupFileGzName);
          if (fileId != null && useGzName) {
            final put = await client.patch(
              Uri.parse('$_driveUploadBase/files/$fileId?uploadType=media'),
              headers: {
                ...headers,
                'Content-Type': 'application/gzip',
                'Content-Encoding': 'gzip',
              },
              body: gzBytes,
            );
            if (put.statusCode != 200) {
              throw 'Drive upload failed ${put.statusCode}: ${SyncText.driveError(put.body)}';
            }
            final mt =
                (jsonDecode(put.body)['modifiedTime'] ?? '') as String;
            if (mt.isNotEmpty) {
              await _db.setMeta('drive_mtime_seen', mt);
            }
            await _db.setMeta('drive_push_hash', snapshotHash);
          } else if (fileId != null) {
            final create = await client.post(
              Uri.parse('$_driveBase/files?fields=id'),
              headers: {...headers, 'Content-Type': 'application/json'},
              body: jsonEncode({
                'name': kBackupFileGzName,
                'parents': ['appDataFolder'],
              }),
            );
            if (create.statusCode != 200 && create.statusCode != 201) {
              throw 'Drive create failed ${create.statusCode}: ${SyncText.driveError(create.body)}';
            }
            final newId = (jsonDecode(create.body)['id'] ?? '') as String;
            if (newId.isEmpty) throw 'Drive create returned no file id.';
            final filled = await client.patch(
              Uri.parse('$_driveUploadBase/files/$newId?uploadType=media'),
              headers: {
                ...headers,
                'Content-Type': 'application/gzip',
                'Content-Encoding': 'gzip',
              },
              body: gzBytes,
            );
            if (filled.statusCode != 200) {
              throw 'Drive upload failed ${filled.statusCode}: ${SyncText.driveError(filled.body)}';
            }
            final mt =
                (jsonDecode(filled.body)['modifiedTime'] ?? '') as String;
            if (mt.isNotEmpty) {
              await _db.setMeta('drive_mtime_seen', mt);
            }
            await _db.setMeta('drive_push_hash', snapshotHash);
          } else {
            final create = await client.post(
              Uri.parse('$_driveBase/files?fields=id'),
              headers: {...headers, 'Content-Type': 'application/json'},
              body: jsonEncode({
                'name': kBackupFileGzName,
                'parents': ['appDataFolder'],
              }),
            );
            if (create.statusCode != 200 && create.statusCode != 201) {
              throw 'Drive create failed ${create.statusCode}: ${SyncText.driveError(create.body)}';
            }
            final newId = (jsonDecode(create.body)['id'] ?? '') as String;
            if (newId.isEmpty) throw 'Drive create returned no file id.';
            final filled = await client.patch(
              Uri.parse('$_driveUploadBase/files/$newId?uploadType=media'),
              headers: {
                ...headers,
                'Content-Type': 'application/gzip',
                'Content-Encoding': 'gzip',
              },
              body: gzBytes,
            );
            if (filled.statusCode != 200) {
              throw 'Drive upload failed ${filled.statusCode}: ${SyncText.driveError(filled.body)}';
            }
            final mt =
                (jsonDecode(filled.body)['modifiedTime'] ?? '') as String;
            if (mt.isNotEmpty) {
              await _db.setMeta('drive_mtime_seen', mt);
            }
            await _db.setMeta('drive_push_hash', snapshotHash);
          }
        } else if (remoteChanged) {
          await _db.setMeta('drive_mtime_seen', remoteMtime ?? '');
        }

        // 5) Bookkeeping
        final now = DateTime.now();
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
    _silentRetry = Timer(const Duration(seconds: 90), () {
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
      final res = await client.get(listUri, headers: headers);
      if (res.statusCode != 200) return null;
      final files = (jsonDecode(res.body)['files'] as List?) ?? const [];
      if (files.isEmpty) return null;
      final first = files.first as Map;
      final modified =
          DateTime.tryParse(first['modifiedTime'] as String? ?? '');
      final dl = await client.get(
        Uri.parse('$_driveBase/files/${first['id']}?alt=media'),
        headers: headers,
      );
      final payload = dl.bodyBytes;
      if (payload.isEmpty) return null;
      final decodedJson = BackupCodec.isGzipped(payload)
          ? utf8.decode(gzip.decode(payload))
          : utf8.decode(payload);
      if (decodedJson.trim().isEmpty) return null;
      final records = BackupCodec.parseEnvelope(jsonDecode(decodedJson));
      final live = records.where((r) => r['deleted'] != true).length;
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
