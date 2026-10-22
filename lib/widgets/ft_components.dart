import 'package:flutter/material.dart';
import '../models/token_record.dart';
import '../theme/app_graphics.dart';
import '../theme/app_theme.dart';

/// Shared building blocks for the v2 design. New file — nothing existing was
/// renamed. Every screen uses these so the whole app looks and behaves alike.

/// Section title: gold marker + text + optional count chip.
class FtSectionTitle extends StatelessWidget {
  final String text;
  final int? count;
  final EdgeInsetsGeometry padding;
  const FtSectionTitle(
    this.text, {
    super.key,
    this.count,
    this.padding = const EdgeInsets.fromLTRB(20, 22, 20, 6),
  });

  @override
  Widget build(BuildContext context) => Padding(
        padding: padding,
        child: Row(
          children: [
            Container(
              width: 4,
              height: 18,
              decoration: BoxDecoration(
                color: AppTheme.accent,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 10),
            Text(
              text,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: AppTheme.ink,
              ),
            ),
            if (count != null) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 2),
                decoration: BoxDecoration(
                  color: AppTheme.tint,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '$count',
                  style: const TextStyle(
                    color: AppTheme.primary,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ],
        ),
      );
}

/// White rounded surface with a hairline border (the app's standard card).
class FtSurface extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final Color? color;
  final Color? borderColor;
  const FtSurface({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.margin = const EdgeInsets.fromLTRB(16, 6, 16, 6),
    this.color,
    this.borderColor,
  });

  @override
  Widget build(BuildContext context) => Container(
        margin: margin,
        padding: padding,
        decoration: BoxDecoration(
          color: color ?? AppTheme.cardBg,
          borderRadius: BorderRadius.circular(AppTheme.rLg),
          border: Border.all(color: borderColor ?? AppTheme.line),
        ),
        child: child,
      );
}

/// Pinned bottom bar: always inside the thumb zone, never scrolls away.
class FtBottomBar extends StatelessWidget {
  final Widget child;
  const FtBottomBar({super.key, required this.child});

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: AppTheme.cardBg,
          boxShadow: [
            BoxShadow(
              color: AppTheme.ink.withValues(alpha: 0.08),
              blurRadius: 12,
              offset: const Offset(0, -3),
            ),
          ],
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
            child: child,
          ),
        ),
      );
}

/// Small rounded label.
class FtPill extends StatelessWidget {
  final String text;
  final Color color;
  final bool filled;
  const FtPill(this.text,
      {super.key, required this.color, this.filled = false});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: filled ? color : color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          text,
          style: TextStyle(
            color: filled ? Colors.white : color,
            fontSize: 10.5,
            fontWeight: FontWeight.w900,
            letterSpacing: 0.7,
          ),
        ),
      );
}

/// Full-width primary action (56 px — easy to hit one-handed).
class FtPrimaryButton extends StatelessWidget {
  final String label;
  final String? iconAsset;
  final VoidCallback? onPressed;
  final bool busy;
  final Color? background;
  final Color? foreground;
  const FtPrimaryButton({
    super.key,
    required this.label,
    this.iconAsset,
    this.onPressed,
    this.busy = false,
    this.background,
    this.foreground,
  });

  @override
  Widget build(BuildContext context) {
    final fg = foreground ?? Colors.white;
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: ElevatedButton(
        onPressed: busy ? null : onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: background ?? AppTheme.primary,
          foregroundColor: fg,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (busy)
              Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2.4, color: fg),
                  ),
                ],
              )
            else if (iconAsset != null)
              AppIcons.svg(iconAsset!, size: 21, color: fg),
            if (busy || iconAsset != null) const SizedBox(width: 10),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w800),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Plain confirm dialog with two big buttons. Returns true when confirmed.
Future<bool> showFtConfirm(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  String cancelLabel = 'Cancel',
  bool danger = false,
  Widget? body,
}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(22, 22, 22, 0),
      contentPadding: const EdgeInsets.fromLTRB(22, 10, 22, 8),
      actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      title: Text(title,
          style: const TextStyle(
              fontWeight: FontWeight.w900, fontSize: 20, color: AppTheme.ink)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(message,
              style: const TextStyle(
                  fontSize: 14, color: AppTheme.textMid, height: 1.4)),
          if (body != null) ...[const SizedBox(height: 14), body],
        ],
      ),
      actions: [
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(cancelLabel),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: ElevatedButton.styleFrom(
                  backgroundColor: danger ? AppTheme.danger : AppTheme.primary,
                ),
                child: Text(confirmLabel,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ),
          ],
        ),
      ],
    ),
  );
  return r == true;
}

/// The one "Use this token?" confirmation, shared by Home and Detail.
Future<bool> showFtUseTokenDialog(BuildContext context, TokenRecord token) {
  return showFtConfirm(
    context,
    title: 'Use this token?',
    message: 'It locks after use. One time only.',
    confirmLabel: 'Yes, use it',
    cancelLabel: 'Not yet',
    body: Container(
      width: double.infinity,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AppTheme.tint,
        borderRadius: BorderRadius.circular(AppTheme.rMd),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(width: 5, color: AppTheme.accent),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: Text(
                              token.tokenCode,
                              maxLines: 1,
                              style: const TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.w900,
                                color: AppTheme.ink,
                                letterSpacing: 1.4,
                              ),
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            token.vehicleNumber.toUpperCase(),
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.textMid,
                              letterSpacing: 1,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (token.subsidyAmount != null)
                      Container(
                        margin: const EdgeInsets.only(left: 10),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: AppTheme.accent.withValues(alpha: 0.4),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          'Rs. ${token.subsidyAmount!.toStringAsFixed(0)}',
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 14,
                            color: AppTheme.ink,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Friendly deadline text: "Today · 16:47", "Tomorrow · 16:47", "3d left · …"
String ftDeadlineLabel(TokenRecord token) {
  final e = token.expiryDate;
  if (token.isExpired) return 'Expired';
  if (e == null) return 'No deadline';
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(e.year, e.month, e.day);
  final daysLeft = day.difference(today).inDays;
  final time =
      '${e.hour.toString().padLeft(2, '0')}:${e.minute.toString().padLeft(2, '0')}';
  const months = [
    '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  if (daysLeft <= 0) return 'Today · $time';
  if (daysLeft == 1) return 'Tomorrow · $time';
  if (daysLeft <= 7) return '${daysLeft}d left · $time';
  return '${e.day} ${months[e.month]} · $time';
}

/// Centered empty / info state used by every list.
class FtEmptyState extends StatelessWidget {
  final Widget art;
  final String title;
  final String message;
  final Widget? action;
  const FtEmptyState({
    super.key,
    required this.art,
    required this.title,
    required this.message,
    this.action,
  });

  @override
  Widget build(BuildContext context) => Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              art,
              const SizedBox(height: 16),
              Text(title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w900,
                      color: AppTheme.ink)),
              const SizedBox(height: 8),
              Text(message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 14, color: AppTheme.textMid, height: 1.5)),
              if (action != null) ...[const SizedBox(height: 20), action!],
            ],
          ),
        ),
      );
}
