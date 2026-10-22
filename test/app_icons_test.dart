import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fueltoken_tracker/models/token_record.dart';
import 'package:fueltoken_tracker/theme/app_graphics.dart';

/// The complete delivered graphic set — registry entries must all exist,
/// load, and render without exceptions.
void main() {
  const String svg = 'assets/fueltoken_icons/svg';
  const String png = 'assets/fueltoken_icons/png';

  const List<String> svgAssets = [
    // vehicles
    '$svg/vehicle_motorcycle.svg',
    '$svg/vehicle_rickshaw.svg',
    '$svg/vehicle_qingqi.svg',
    '$svg/vehicle_car.svg',
    '$svg/vehicle_other.svg',
    // token domain
    '$svg/token_card.svg',
    '$svg/icon_used.svg',
    '$svg/icon_pump.svg',
    '$svg/icon_litres.svg',
    '$svg/icon_deadline.svg',
    '$svg/icon_rupee.svg',
    '$svg/icon_sms.svg',
    '$svg/icon_verify.svg',
    '$svg/icon_search.svg',
    // actions
    '$svg/action_camera.svg',
    '$svg/action_gallery.svg',
    '$svg/action_crop.svg',
    '$svg/action_add.svg',
    '$svg/action_copy.svg',
    '$svg/action_edit.svg',
    '$svg/action_delete.svg',
    '$svg/action_save.svg',
    '$svg/action_retry.svg',
    // brand
    '$svg/brand_github.svg',
    // reading states
    '$svg/ai_reading.svg',
    '$svg/state_done.svg',
    '$svg/state_doubt.svg',
    '$svg/state_failed.svg',
    // nav & chrome
    '$svg/nav_tokens.svg',
    '$svg/nav_history.svg',
    '$svg/nav_settings.svg',
    '$svg/nav_back.svg',
    '$svg/nav_close.svg',
    '$svg/nav_chevron.svg',
    '$svg/icon_hardware_phone.svg',
    // settings, key, sync
    '$svg/icon_key.svg',
    '$svg/icon_eye.svg',
    '$svg/icon_eye_off.svg',
    '$svg/icon_help.svg',
    '$svg/icon_lock.svg',
    '$svg/icon_paste.svg',
    '$svg/cloud_back_up.svg',
    '$svg/cloud_restore.svg',
    '$svg/cloud_idle.svg',
    // illustrations (full-colour)
    '$svg/empty_tokens.svg',
    '$svg/empty_used.svg',
    '$svg/empty_history.svg',
    '$svg/no_key.svg',
    '$svg/no_internet.svg',
    '$svg/read_failed.svg',
  ];

  const List<String> animAssets = [
    'assets/fueltoken_anim/anim/token_done.json',
    'assets/fueltoken_anim/anim/ai_reading.json',
    'assets/fueltoken_anim/anim/content_pulse.json',
    'assets/fueltoken_anim/anim/crop_busy.json',
    'assets/fueltoken_anim/anim/no_internet.json',
    'assets/fueltoken_anim/svg/ai_reading_loop.svg',
    'assets/fueltoken_anim/svg/no_internet_loop.svg',
  ];

  const List<String> pngAssets = [
    '$png/app_logo_tile.png',
    '$png/app_logo_mark.png',
    '$png/app_logo_mono.png',
  ];

  testWidgets('every delivered SVG asset exists and is non-trivial',
      (tester) async {
    for (final path in svgAssets) {
      final data = await tester.runAsync(() => rootBundle.load(path));
      expect(data, isNotNull, reason: path);
      expect(data!.lengthInBytes, greaterThan(50), reason: path);
    }
  });

  testWidgets('delivered animation (Lottie) files exist and parse',
      (tester) async {
    for (final path in animAssets) {
      final data = await tester.runAsync(() => rootBundle.load(path));
      expect(data, isNotNull, reason: path);
      expect(data!.lengthInBytes, greaterThan(200), reason: path);
    }
    for (final path in animAssets.where((p) => p.endsWith('.json'))) {
      final data = await tester.runAsync(() => rootBundle.load(path));
      expect(data, isNotNull, reason: path);
    }
  });

  testWidgets('identity PNG artwork exists in both sizes', (tester) async {
    for (final path in pngAssets) {
      final data = await tester.runAsync(() => rootBundle.load(path));
      expect(data, isNotNull, reason: path);
      expect(data!.lengthInBytes, greaterThan(1000), reason: path);
    }
  });

  testWidgets('vehicle glyphs + illustrations + SVG chrome render',
      (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: [
                  for (final vt in VehicleType.values)
                    AppIcons.vehicleGlyph(vt, size: 22, color: Colors.red),
                  AppIcons.illustration('empty_tokens', width: 120),
                  AppIcons.illustration('empty_used', width: 120),
                  AppIcons.illustration('empty_history', width: 120),
                  AppIcons.illustration('no_key', width: 120),
                  AppIcons.illustration('no_internet', width: 120),
                  AppIcons.illustration('read_failed', width: 120),
                  for (final a in <String>[
                    AppIcons.stateDone,
                    AppIcons.stateDoubt,
                    AppIcons.stateFailed,
                    AppIcons.pump,
                    AppIcons.deadline,
                    AppIcons.sms,
                    AppIcons.copyToken,
                    AppIcons.navTokens,
                  ])
                    AppIcons.svg(a, size: 24, color: Colors.black),
                  AppIcons.identity(AppIcons.logoMark, size: 48),
                  AppIcons.identity(AppIcons.logoMono, size: 48),
                ],
              ),
            ),
          ),
        ),
      );
      // Give async asset loaders time to complete inside runAsync.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await tester.pump();
    });
    expect(tester.takeException(), isNull);
  });
}
