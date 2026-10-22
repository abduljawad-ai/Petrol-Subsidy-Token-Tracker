import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../db/database_helper.dart';
import '../models/token_record.dart';

/// Offline renewal reminders. When a token's expiry day ends — used or not —
/// Android fires: "Token expired — request a new token". Schedules are
/// re-done from scratch after every database write, so they stay fresh after
/// edits, deletes, restores and sync. All offline; nothing here needs the
/// network.
class TokenNotifications {
  TokenNotifications._();
  static final TokenNotifications instance = TokenNotifications._();

  final _plugin = FlutterLocalNotificationsPlugin();
  Timer? _debounce;
  bool _ready = false;
  tz.Location _zone = tz.UTC; // upgraded to the phone's zone in init()

  static const _channelId = 'token_expiry';
  static const _channelName = 'Token expiry';

  Future<void> init() async {
    if (_ready) return;
    try {
      // Time zone: try the phone's name, fall back to UTC instants (which
      // still fire at the right absolute time, just stored differently).
      try {
        tzdata.initializeTimeZones();
        _zone = tz.getLocation(await FlutterTimezone.getLocalTimezone());
      } catch (_) {
        _zone = tz.UTC;
      }
      await _plugin.initialize(const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher')));
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await android?.createNotificationChannel(const AndroidNotificationChannel(
        _channelId,
        _channelName,
        description:
            'Fires when a token expires and its vehicle can request a new one.',
      ));
      // Android 13+ asks the first time; older systems don't need it.
      await android?.requestNotificationsPermission();
      _ready = true;
    } catch (_) {
      _ready = false;
    }
  }

  /// Database write hook — coalesces bursts into one rebuild.
  void onDatabaseWrite(DatabaseHelper db) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      _rebuild(db);
    });
  }

  Future<void> _rebuild(DatabaseHelper db) async {
    if (!_ready) return;
    try {
      final tokens = await db.getAllTokens();
      await _plugin.cancelAll();
      final now = DateTime.now();
      for (final t in tokens) {
        await _scheduleExpiry(t, now);
      }
    } catch (_) {
      // Reminders are best-effort; the in-app renew section never fails.
    }
  }

  Future<void> _scheduleExpiry(TokenRecord t, DateTime now) async {
    final e = t.expiryDate;
    if (e == null) return;
    final endOfDay = DateTime(e.year, e.month, e.day, 23, 59, 59);
    if (!endOfDay.isAfter(now)) return; // already passed — renew list covers it
    final vehicle = t.vehicleNumber.trim().toUpperCase();
    await _plugin.zonedSchedule(
      _idFor(t.id),
      'Token expired — request a new one',
      '$vehicle: the token has expired. You can request a new token for '
      'this vehicle now.',
      tz.TZDateTime.from(endOfDay, _zone),
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription:
              'Fires when a token expires and its vehicle can request a new one.',
          styleInformation: BigTextStyleInformation(''),
        ),
      ),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
    );
  }

  /// Stable id per token; survives reschedules across app restarts.
  int _idFor(String tokenId) => tokenId.hashCode & 0x7FFFFFFF;
}
