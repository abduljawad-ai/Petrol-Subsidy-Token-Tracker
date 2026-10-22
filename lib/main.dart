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
  // Lock to portrait orientation
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  // Sync engine boot: instant auto-load from Drive when a session exists.
  // (No-op until the user signs up — see SYNC_PLAN.md.)
  unawaited(DriveSyncService.instance.init());
  // Offline renewal reminders: fire when a token's expiry day ends.
  await TokenNotifications.instance.init();
  DatabaseHelper.addWriteListener(
      (db) => TokenNotifications.instance.onDatabaseWrite(db));
  runApp(const FuelTokenApp());
}

class FuelTokenApp extends StatelessWidget {
  const FuelTokenApp({super.key});

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
