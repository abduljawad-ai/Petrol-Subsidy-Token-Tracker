import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../db/database_helper.dart';
import '../models/token_record.dart';
import 'renewal_service.dart';

/// A snapshot of everything that can stop a reminder from reaching the phone.
/// Shown in Settings so a user (and support) can see the real device state
/// instead of guessing why no notification appeared.
class ReminderDiagnostics {
  final bool ready;
  final bool notificationsEnabled;
  final bool exactAlarmsAllowed;
  final bool channelEnabled;
  final int pendingCount;
  final int lastScheduled;
  final DateTime? lastRebuildAt;
  final String? lastError;

  const ReminderDiagnostics({
    required this.ready,
    required this.notificationsEnabled,
    required this.exactAlarmsAllowed,
    required this.channelEnabled,
    required this.pendingCount,
    required this.lastScheduled,
    required this.lastRebuildAt,
    required this.lastError,
  });
}

/// Offline renewal reminders.
///
/// When a token's exact expiry instant passes — used or not — Android fires
/// "Token expired". While the vehicle is still due, three further reminders a
/// day (09:00, 15:00, 20:00) keep nudging the user until a newer token for that
/// vehicle is added. Schedules are re-derived from scratch after every database
/// write, at app start, and on every resume, so they stay fresh after edits,
/// deletes, restores, sync, reboots and time-zone changes. All offline.
class TokenNotifications {
  TokenNotifications._();
  static final TokenNotifications instance = TokenNotifications._();

  final _plugin = FlutterLocalNotificationsPlugin();
  Timer? _debounce;
  Future<void>? _initInFlight;
  Future<void> _rebuildQueue = Future<void>.value();
  bool _ready = false;
  tz.Location _zone = tz.UTC; // upgraded to the phone's zone in init()
  String? _lastSignature;

  bool _notificationsEnabled = false;
  bool _exactAllowed = false;
  bool _channelEnabled = true;
  int _lastScheduled = 0;
  DateTime? _lastRebuildAt;
  String? _lastError;

  static const _channelId = 'token_expiry';
  static const _channelName = 'Token expiry';
  static const _channelDescription =
      'Fires when a token expires and repeats while the vehicle is due.';
  static const _expiryTitle = 'Token expired — request a new one';
  static const _reminderTitle = 'Token still due — request a new one';
  static const _testNotificationId = 0x7FFF0001;

  /// One immediate notice per token/expiry, even across app restarts, so a
  /// token that expired while the phone was off still announces itself the
  /// next time the app opens — without repeating on every resume.
  static const _notifiedMetaPrefix = 'token_expiry_notified_';

  /// Three nudges a day while the vehicle has no fresh token.
  static const _reminderHours = <int>[9, 15, 20];

  /// How far ahead one-shot reminders are queued for a token that has not
  /// expired yet. Once the expiry instant has passed, a rebuild switches the
  /// vehicle to three lightweight repeating alarms instead, so the nudges
  /// continue until a newer token is added.
  static const _reminderDays = 14;

  AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();

  static const AndroidNotificationChannel _channel = AndroidNotificationChannel(
    _channelId,
    _channelName,
    description: _channelDescription,
    importance: Importance.high,
  );

  /// Idempotent. A transient failure (e.g. plugin not attached yet) leaves the
  /// service retryable instead of permanently disabling reminders.
  Future<void> init() {
    if (_ready) return Future<void>.value();
    return _initInFlight ??= _doInit().whenComplete(() {
      if (!_ready) _initInFlight = null;
    });
  }

  Future<void> _doInit() async {
    try {
      try {
        tzdata.initializeTimeZones();
        _zone = tz.getLocation(await FlutterTimezone.getLocalTimezone());
      } catch (_) {
        // Unknown zone name: UTC instants still fire at the right absolute
        // time, they are just stored/rendered differently.
        _zone = tz.UTC;
      }
      await _plugin.initialize(const InitializationSettings(
          android: AndroidInitializationSettings('ic_notification')));

      final android = _android;
      await android?.createNotificationChannel(_channel);
      _notificationsEnabled =
          await android?.areNotificationsEnabled() ?? false;
      _exactAllowed =
          await android?.canScheduleExactNotifications() ?? false;

      _ready = true;
      _lastError = null;
      debugPrint('TokenNotifications: ready zone=${_zone.name} '
          'notifications=$_notificationsEnabled exact=$_exactAllowed');
    } catch (e, st) {
      _ready = false;
      _lastError = 'Could not start reminders: $e';
      debugPrint('TokenNotifications: init failed: $e\n$st');
    }
  }

  /// Ask for the Android 13+ notification permission. Must run after the
  /// first frame: the plugin needs the activity attached, otherwise the
  /// request is silently dropped and reminders can never appear.
  ///
  /// When [db] is supplied and permission was newly granted, rebuild at once
  /// so an already-expired token gets its immediate notice instead of waiting
  /// for the next app resume.
  Future<bool> requestPermissionIfNeeded({DatabaseHelper? db}) async {
    await init();
    final android = _android;
    if (android == null) return false;
    try {
      final wasEnabled = _notificationsEnabled;
      _notificationsEnabled =
          await android.areNotificationsEnabled() ?? false;
      if (!_notificationsEnabled) {
        _notificationsEnabled =
            await android.requestNotificationsPermission() ?? false;
      }
      if (!wasEnabled && _notificationsEnabled && db != null) {
        await rebuild(db, force: true);
      }
      debugPrint('TokenNotifications: notifications enabled='
          '$_notificationsEnabled');
      return _notificationsEnabled;
    } catch (e) {
      _lastError = 'Could not ask for notification permission: $e';
      debugPrint('TokenNotifications: notification permission failed: $e');
      return false;
    }
  }

  /// Opens Android's "Alarms & reminders" screen. The returned future completes
  /// when the user comes back; callers should refresh their status afterwards.
  Future<bool> requestExactAlarmPermission() async {
    await init();
    final android = _android;
    if (android == null) return false;
    try {
      _exactAllowed =
          await android.canScheduleExactNotifications() ?? false;
      if (!_exactAllowed) {
        _exactAllowed =
            await android.requestExactAlarmsPermission() ?? false;
      }
      debugPrint('TokenNotifications: exact alarms allowed=$_exactAllowed');
      return _exactAllowed;
    } catch (e) {
      _lastError = 'Could not open exact alarm settings: $e';
      debugPrint('TokenNotifications: exact alarm permission failed: $e');
      return false;
    }
  }

  /// Sends an immediate notification so the user can prove the channel and
  /// permission work without waiting for a real token to expire.
  Future<bool> showTestNotification() async {
    await init();
    if (!_ready) return false;
    try {
      await _android?.createNotificationChannel(_channel);
      const body = 'You will be notified the moment a token expires, then at '
          '09:00, 15:00 and 20:00 while a vehicle is due.';
      await _plugin.show(
        _testNotificationId,
        'Reminders are working',
        body,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            _channelName,
            channelDescription: _channelDescription,
            importance: Importance.high,
            priority: Priority.high,
            styleInformation: BigTextStyleInformation(body),
          ),
        ),
      );
      debugPrint('TokenNotifications: test notification sent');
      return true;
    } catch (e, st) {
      _lastError = 'Test notification failed: $e';
      debugPrint('TokenNotifications: test notification failed: $e\n$st');
      return false;
    }
  }

  /// Live device state for the Settings card.
  Future<ReminderDiagnostics> diagnostics() async {
    await init();
    final android = _android;
    var enabled = _notificationsEnabled;
    var exact = _exactAllowed;
    var channelEnabled = _channelEnabled;
    var pending = 0;
    try {
      if (android != null) {
        enabled = await android.areNotificationsEnabled() ?? enabled;
        exact = await android.canScheduleExactNotifications() ?? exact;
        final channels =
            await android.getNotificationChannels() ?? const [];
        for (final c in channels) {
          if (c.id == _channelId) {
            channelEnabled = c.importance != Importance.none;
            break;
          }
        }
      }
      pending = (await _plugin.pendingNotificationRequests()).length;
    } catch (e) {
      debugPrint('TokenNotifications: diagnostics failed: $e');
    }
    _notificationsEnabled = enabled;
    _exactAllowed = exact;
    _channelEnabled = channelEnabled;
    return ReminderDiagnostics(
      ready: _ready,
      notificationsEnabled: enabled,
      exactAlarmsAllowed: exact,
      channelEnabled: channelEnabled,
      pendingCount: pending,
      lastScheduled: _lastScheduled,
      lastRebuildAt: _lastRebuildAt,
      lastError: _lastError,
    );
  }

  /// Database write hook — coalesces bursts into one rebuild.
  void onDatabaseWrite(DatabaseHelper db) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      unawaited(rebuild(db));
    });
  }

  /// Immediate rebuild. Safe to call at startup and on every app resume:
  /// Android drops scheduled alarms after a reboot or a force-stop, and the
  /// user may have granted/revoked permissions while the app was away.
  ///
  /// Rebuilds are serialized: two overlapping runs (startup + resume + write)
  /// would otherwise cancel each other's freshly scheduled alarms.
  ///
  /// [force] bypasses the "nothing changed" signature check, for the Settings
  /// card's manual refresh and for a test after granting a permission.
  Future<void> rebuild(DatabaseHelper db, {bool force = false}) {
    _debounce?.cancel();
    final next = _rebuildQueue.then((_) => _rebuildOnce(db, force: force));
    _rebuildQueue = next.catchError((_) {});
    return next;
  }

  Future<void> _rebuildOnce(DatabaseHelper db, {bool force = false}) async {
    await init();
    if (!_ready) {
      debugPrint('TokenNotifications: rebuild skipped — not ready');
      return;
    }
    try {
      // Pick up a time-zone change since the last run so 09:00/15:00/20:00
      // stay wall-clock times where the user actually is.
      try {
        _zone = tz.getLocation(await FlutterTimezone.getLocalTimezone());
      } catch (_) {
        // Keep the last known zone.
      }
      final tokens = await db.getAllTokens();
      final latest = RenewalService.latestPerVehicle(tokens);

      final android = _android;
      final exact = await android?.canScheduleExactNotifications() ?? false;
      final enabled = await android?.areNotificationsEnabled() ?? false;
      _exactAllowed = exact;
      _notificationsEnabled = enabled;

      final now = DateTime.now();
      // Nothing relevant changed since the last successful rebuild (a resumed
      // app keeps its alarms): skip the cancel/reschedule churn. A reboot,
      // force-stop or app update starts a fresh process, so _lastSignature is
      // null and the alarms are always re-armed then.
      final signature =
          _signature(latest, now, exact: exact, enabled: enabled);
      if (!force && signature == _lastSignature) {
        debugPrint('TokenNotifications: unchanged — ${latest.length} '
            'vehicles, notifications=$enabled, exact=$exact');
        return;
      }

      // Pending only: delivered reminders stay in the shade until dismissed.
      await _plugin.cancelAllPendingNotifications();

      var complete = true;
      var scheduled = 0;
      // One reminder set per VEHICLE, judged by its most recent token — the
      // same rule RenewalService uses to decide who may request a new token.
      for (final t in latest.values) {
        try {
          scheduled += await _scheduleFor(t, now, exact: exact);
          // If the app only learns about the expiry now (added late, resumed
          // after being off, or the alarm was killed), announce it at once
          // instead of waiting up to eleven hours for the next 09/15/20 slot.
          if (_isExpired(t, now)) {
            await _notifyExpiredOnce(db, t);
          }
        } catch (e, st) {
          // One malformed row must never block the other vehicles' alarms.
          complete = false;
          _lastError =
              'Reminder schedule failed for ${t.vehicleNumber}: $e';
          debugPrint('TokenNotifications: schedule failed for ${t.id} '
              '(${t.vehicleNumber}): $e\n$st');
        }
      }
      _lastScheduled = scheduled;
      _lastRebuildAt = now;
      if (complete) {
        _lastSignature = signature;
        _lastError = null;
      }
      debugPrint('TokenNotifications: rebuilt ${latest.length} vehicles, '
          '$scheduled alarms queued, notifications=$enabled, exact=$exact, '
          'pending=${(await _plugin.pendingNotificationRequests()).length}');
    } catch (e, st) {
      _lastError = 'Reminder rebuild failed: $e';
      debugPrint('TokenNotifications: rebuild failed: $e\n$st');
    }
  }

  /// Everything the schedule depends on: per vehicle the newest token's id,
  /// code, plate and expiry (plus whether it has already lapsed), the exact
  /// alarm permission, notification permission and the local zone. Owner/
  /// status edits deliberately do not invalidate the queue.
  String _signature(
    Map<String, TokenRecord> latest,
    DateTime now, {
    required bool exact,
    required bool enabled,
  }) {
    final parts = latest.values
        .map((t) => '${t.id}|${t.tokenCode}|${t.vehicleNumber}|'
            '${t.expiryDate?.millisecondsSinceEpoch ?? 0}|'
            '${t.expiryDate != null && !t.expiryDate!.isAfter(now) ? 1 : 0}')
        .toList()
      ..sort();
    return '${_zone.name}|$exact|$enabled|${parts.join('|')}';
  }

  static bool _isExpired(TokenRecord t, DateTime now) {
    final e = t.expiryDate;
    return e != null && !e.isAfter(now);
  }

  String _bodyFor(TokenRecord t) {
    final e = t.expiryDate!;
    final vehicle = t.vehicleNumber.trim().toUpperCase();
    return '$vehicle: token ${t.tokenCode} expired on ${_fmtWhen(e)}. '
        'You can request a new token for this vehicle now.';
  }

  NotificationDetails _detailsFor(TokenRecord t) {
    final body = _bodyFor(t);
    return NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: _channelDescription,
        importance: Importance.high,
        priority: Priority.high,
        styleInformation: BigTextStyleInformation(body),
      ),
    );
  }

  static int _exactId(TokenRecord t) =>
      _idFor('${t.id}|${t.expiryDate!.millisecondsSinceEpoch}|expiry');

  /// Immediate "it has expired" notice, at most once per token/expiry. The
  /// marker lives in the DB meta table so a process restart does not repeat
  /// it, and a renewed token (new id / new expiry) announces itself again.
  ///
  /// If the exact expiry alarm already delivered its notification, skip: the
  /// user has seen it, and a second copy on app open would just be noise.
  Future<void> _notifyExpiredOnce(DatabaseHelper db, TokenRecord t) async {
    final e = t.expiryDate;
    if (e == null || !_notificationsEnabled) return;
    final key = '$_notifiedMetaPrefix${t.id}';
    final stamp = '${e.millisecondsSinceEpoch}';
    try {
      if (await db.getMeta(key) == stamp) return;
      var alreadyDelivered = false;
      try {
        final active = await _plugin.getActiveNotifications();
        alreadyDelivered = active.any((n) => n.id == _exactId(t));
      } catch (_) {
        // Active-notification lookup is Android 6+ only; if it is
        // unavailable, the immediate notice is still safe to show.
      }
      if (!alreadyDelivered) {
        await _plugin.show(
          _idFor('${t.id}|${e.millisecondsSinceEpoch}|expired-now'),
          _expiryTitle,
          _bodyFor(t),
          _detailsFor(t),
        );
        debugPrint('TokenNotifications: immediate expiry notice for ${t.id}');
      }
      await db.setMeta(key, stamp);
    } catch (e, st) {
      debugPrint(
          'TokenNotifications: immediate notice failed for ${t.id}: $e\n$st');
      rethrow;
    }
  }

  Future<int> _scheduleFor(
    TokenRecord t,
    DateTime now, {
    required bool exact,
  }) async {
    final e = t.expiryDate;
    if (e == null) return 0;
    final vehicle = t.vehicleNumber.trim().toUpperCase();
    if (vehicle.isEmpty) return 0;

    final body = _bodyFor(t);
    final details = _detailsFor(t);
    var scheduled = 0;

    // 1) The exact expiry instant: fire the moment the token lapses.
    if (e.isAfter(now)) {
      await _scheduleOneShot(
        id: _exactId(t),
        when: tz.TZDateTime.from(e, _zone),
        title: _expiryTitle,
        body: body,
        details: details,
        exact: exact,
      );
      scheduled++;

      // 2a) Queue the first two weeks of nudges as explicit one-shots. A
      // repeating 09:00 alarm scheduled now would fire today at 09:00 even
      // when the token only expires tonight, so it cannot be used before
      // expiry.
      for (final slot in reminderSlots(e, now)) {
        await _scheduleOneShot(
          id: _idFor('${t.id}|${_dayKey(slot)}|${slot.hour}'),
          when: tz.TZDateTime.from(slot, _zone),
          title: _reminderTitle,
          body: body,
          details: details,
          // Battery-friendly and permission-free. The exact expiry instant
          // above is the one that must be punctual.
          exact: false,
        );
        scheduled++;
      }
      return scheduled;
    }

    // 2b) Already expired: three repeating alarms are safe (the next
    // occurrence of each time-of-day is after now) and cost only three slots
    // in the plugin's schedule cache, however long the vehicle stays due.
    // A later rebuild after renewal cancels them and schedules the new token.
    for (final hour in _reminderHours) {
      var target = DateTime(now.year, now.month, now.day, hour);
      if (!target.isAfter(now)) {
        target = target.add(const Duration(days: 1));
      }
      await _plugin.zonedSchedule(
        _idFor('${t.id}|repeat|$hour'),
        _reminderTitle,
        body,
        tz.TZDateTime.from(target, _zone),
        details,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        matchDateTimeComponents: DateTimeComponents.time,
      );
      scheduled++;
    }
    return scheduled;
  }

  /// Pure schedule plan: the one-shot reminder slots for the next [days] days,
  /// starting strictly AFTER the expiry instant. Exposed for tests.
  static List<DateTime> reminderSlots(
    DateTime expiry,
    DateTime now, {
    int days = _reminderDays,
    List<int> hours = _reminderHours,
  }) {
    final base = expiry.isAfter(now) ? expiry : now;
    final firstDay = DateTime(base.year, base.month, base.day);
    final out = <DateTime>[];
    for (var day = 0; day < days; day++) {
      final date = firstDay.add(Duration(days: day));
      for (final hour in hours) {
        final slot = DateTime(date.year, date.month, date.day, hour);
        if (!slot.isAfter(base)) continue; // same day, before the expiry
        out.add(slot);
      }
    }
    return out;
  }

  Future<void> _scheduleOneShot({
    required int id,
    required tz.TZDateTime when,
    required String title,
    required String body,
    required NotificationDetails details,
    required bool exact,
  }) async {
    Future<void> schedule(AndroidScheduleMode mode) => _plugin.zonedSchedule(
          id,
          title,
          body,
          when,
          details,
          androidScheduleMode: mode,
        );

    if (!exact) {
      await schedule(AndroidScheduleMode.inexactAllowWhileIdle);
      return;
    }
    try {
      await schedule(AndroidScheduleMode.exactAllowWhileIdle);
    } on PlatformException catch (e) {
      // Permission revoked between the check and the call: degrade quietly.
      if (e.code != 'exact_alarms_not_permitted') rethrow;
      debugPrint('TokenNotifications: exact alarm denied, using inexact');
      await schedule(AndroidScheduleMode.inexactAllowWhileIdle);
    }
  }

  static String _fmtWhen(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}-${_monthAbbr(d.month)} '
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  static String _monthAbbr(int m) => const [
        '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
      ][m];

  static String _dayKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// Stable FNV-1a id. `String.hashCode` is randomized per process on Dart,
  /// which used to orphan previously scheduled alarms.
  static int _idFor(String key) {
    var hash = 0x811c9dc5;
    for (final unit in key.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash & 0x7FFFFFFF;
  }
}
