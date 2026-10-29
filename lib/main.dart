import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'theme/app_theme.dart';
import 'screens/home_screen.dart';
import 'db/database_helper.dart';
import 'services/drive_sync_service.dart';
import 'services/token_notifications.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Lock to portrait orientation before the first frame.
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  // Show the UI first: notification/timezone/Drive boot work must never delay
  // the first frame.
  runApp(const FuelTokenApp());

  // Sync engine boot: instant auto-load from Drive when a session exists.
  // (No-op until the user signs up — see SYNC_PLAN.md.)
  unawaited(DriveSyncService.instance.init());

  // Offline renewal reminders: fire at the exact expiry instant, then three
  // nudges a day until a newer token for that vehicle is added.
  // The listener is registered before any user-triggered DB write; the
  // startup rebuild re-arms alarms that Android dropped after a reboot,
  // force-stop or app update.
  DatabaseHelper.addChangeListener(
      (helper) => TokenNotifications.instance.onDatabaseWrite(helper));
  unawaited(TokenNotifications.instance.rebuild(DatabaseHelper()));
}

class FuelTokenApp extends StatefulWidget {
  const FuelTokenApp({super.key});

  @override
  State<FuelTokenApp> createState() => _FuelTokenAppState();
}

class _FuelTokenAppState extends State<FuelTokenApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Ask for notification permission only after the first frame: the
    // Android plugin needs the activity attached, and a request made from
    // main() can be silently dropped — which is exactly how an app ends up
    // scheduling reminders that the OS never displays.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(TokenNotifications.instance
          .requestPermissionIfNeeded(db: DatabaseHelper()));
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // Re-arm reminders: Android drops alarms while the app is force-stopped,
    // and the user may have granted/revoked permission or changed time zone
    // while the app was away.
    unawaited(TokenNotifications.instance.rebuild(DatabaseHelper()));
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FuelToken Tracker',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      home: const HomeScreen(),
    );
  }
}
