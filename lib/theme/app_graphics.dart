import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:lottie/lottie.dart';

import '../models/token_record.dart';

/// App graphic system — the full FuelToken icon set shipped by the design
/// pass (`assets/fueltoken_icons/{svg,png}`).
///
/// Line glyphs inherit tint via [ColorFilter.mode(srcIn)] so one asset works
/// on light cards (ink) and green appbars (white/gold). Illustrations and the
/// launcher artwork ship pre-colored (PNG) or full-colour (SVG) as delivered.
class AppIcons {
  AppIcons._();

  static const String _svg = 'assets/fueltoken_icons/svg';
  static const String _png = 'assets/fueltoken_icons/png';

  // ── Identity (pre-colored) ────────────────────────────────────────────────
  static const String logoTile = '$_png/app_logo_tile.png';
  static const String logoMark = '$_png/app_logo_mark.png';
  static const String logoMono = '$_png/app_logo_mono.png';

  // ── Vehicles ──────────────────────────────────────────────────────────────
  static const String bike = '$_svg/vehicle_motorcycle.svg';
  static const String rickshaw = '$_svg/vehicle_rickshaw.svg';
  static const String qingqi = '$_svg/vehicle_qingqi.svg';
  static const String car = '$_svg/vehicle_car.svg';
  static const String other = '$_svg/vehicle_other.svg';

  static String vehicleAsset(VehicleType t) => switch (t) {
        VehicleType.motorcycle => bike,
        VehicleType.rickshaw => rickshaw,
        VehicleType.qingqi => qingqi,
        VehicleType.smallCar => car,
        VehicleType.other => other,
      };

  // ── Token domain ──────────────────────────────────────────────────────────
  static const String tokenCard = '$_svg/token_card.svg';
  static const String tokenUsed = '$_svg/icon_used.svg';
  static const String pump = '$_svg/icon_pump.svg';
  static const String litres = '$_svg/icon_litres.svg';
  static const String deadline = '$_svg/icon_deadline.svg';
  static const String rupee = '$_svg/icon_rupee.svg';
  static const String sms = '$_svg/icon_sms.svg';
  static const String verify = '$_svg/icon_verify.svg';
  static const String search = '$_svg/icon_search.svg';

  // ── Actions ───────────────────────────────────────────────────────────────
  static const String camera = '$_svg/action_camera.svg';
  static const String gallery = '$_svg/action_gallery.svg';
  static const String crop = '$_svg/action_crop.svg';
  static const String add = '$_svg/action_add.svg';
  static const String copyToken = '$_svg/action_copy.svg';
  static const String editToken = '$_svg/action_edit.svg';
  static const String deleteToken = '$_svg/action_delete.svg';
  static const String saveToken = '$_svg/action_save.svg';
  static const String retry = '$_svg/action_retry.svg';

  // ── Reading states ────────────────────────────────────────────────────────
  static const String aiReading = '$_svg/ai_reading.svg';
  static const String stateDone = '$_svg/state_done.svg';
  static const String stateDoubt = '$_svg/state_doubt.svg';
  static const String stateFailed = '$_svg/state_failed.svg';

  // ── Brand links ──────────────────────────────────────────────────────────
  static const String brandGithub = '$_svg/brand_github.svg';

  // ── Navigation & chrome ───────────────────────────────────────────────────
  static const String navTokens = '$_svg/nav_tokens.svg';
  static const String navHistory = '$_svg/nav_history.svg';
  static const String navSettings = '$_svg/nav_settings.svg';
  static const String navBack = '$_svg/nav_back.svg';
  static const String navClose = '$_svg/nav_close.svg';
  static const String navChevron = '$_svg/nav_chevron.svg';
  static const String hardwarePhone = '$_svg/icon_hardware_phone.svg';

  // ── Settings, key, sync ───────────────────────────────────────────────────
  static const String keyOcr = '$_svg/icon_key.svg';
  static const String eye = '$_svg/icon_eye.svg';
  static const String eyeOff = '$_svg/icon_eye_off.svg';
  static const String help = '$_svg/icon_help.svg';
  static const String lock = '$_svg/icon_lock.svg';
  static const String paste = '$_svg/icon_paste.svg';
  static const String cloudBackUp = '$_svg/cloud_back_up.svg';
  static const String cloudRestore = '$_svg/cloud_restore.svg';
  static const String cloudIdle = '$_svg/cloud_idle.svg';

  // ── Illustrations (full-colour) ───────────────────────────────────────────
  static const String illEmptyTokens = '$_svg/empty_tokens.svg';
  static const String illEmptyUsed = '$_svg/empty_used.svg';
  static const String illEmptyHistory = '$_svg/empty_history.svg';
  static const String illNoKey = '$_svg/no_key.svg';
  static const String illNoInternet = '$_svg/no_internet.svg';
  static const String illReadFailed = '$_svg/read_failed.svg';

  // ── Motion (Lottie set delivered by the design pass) ─────────────────────
  static const String animAiReading = 'ai_reading';
  static const String animContentPulse = 'content_pulse';
  static const String animCropBusy = 'crop_busy';
  static const String animNoInternet = 'no_internet';
  static const String animTokenDone = 'token_done';

  /// Rotation-safe fallback art (only used if a Lottie file fails to load).
  static const Map<String, String> _lottieFallbacks = {
    animAiReading: '$_svg/ai_reading_loop.svg',
    animNoInternet: '$_svg/no_internet_loop.svg',
  };

  /// Plays a delivered Lottie loop/event. `repeat` false = single run
  /// (the animation stops on its final frame — ideal for event bursts).
  static Widget lottie(String name,
      {double size = 24, bool repeat = true, BoxFit fit = BoxFit.contain}) {
    return Lottie.asset(
      'assets/fueltoken_anim/anim/$name.json',
      width: size,
      height: size,
      repeat: repeat,
      animate: true,
      fit: fit,
      filterQuality: FilterQuality.low,
      errorBuilder: (ctx, err, stack) => svg(
        _lottieFallbacks[name] ?? illNoInternet,
        size: size,
      ),
    );
  }

  // ── Render helpers ────────────────────────────────────────────────────────

  /// Any named line glyph from the set. `color` null = asset's own
  /// `currentColor` (renders black; always pass a color in real UI).
  static Widget svg(String asset, {double size = 22, Color? color}) =>
      SvgPicture.asset(
        asset,
        width: size,
        height: size,
        colorFilter:
            color == null ? null : ColorFilter.mode(color, BlendMode.srcIn),
        clipBehavior: Clip.none,
      );

  /// Vehicle-type glyph (line DNA, tintable).
  static Widget vehicleGlyph(
    VehicleType t, {
    double size = 22,
    Color? color,
  }) =>
      svg(vehicleAsset(t), size: size, color: color);

  /// Pre-colored identity artwork rendered from PNG.
  static Widget identity(
    String asset, {
    double? size,
    double? width,
    BoxFit fit = BoxFit.contain,
  }) =>
      Image.asset(asset, width: width, height: size, fit: fit);

  /// Full-colour empty-state illustration by file stem.
  static Widget illustration(
    String name, {
    double width = 180,
    BoxFit fit = BoxFit.contain,
  }) =>
      SvgPicture.asset(
        '$_svg/$name.svg',
        width: width,
        fit: fit,
        clipBehavior: Clip.none,
      );
}
