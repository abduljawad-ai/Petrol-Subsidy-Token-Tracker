import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../models/token_record.dart';
import '../theme/app_graphics.dart';
import '../theme/app_theme.dart';

/// The pump-attendant-friendly token card shown on the home screen.
///
/// Layout (v2): a "ticket" — status strip on top, the token number as the
/// hero on a soft tint panel with a gold edge, vehicle + countdown row, and a
/// full-width one-time USE button. The token number is never truncated,
/// blurred or animated over.
class ActiveTokenCard extends StatelessWidget {
  final TokenRecord token;
  final VoidCallback? onUseToken;
  final VoidCallback? onTap;

  const ActiveTokenCard({
    super.key,
    required this.token,
    this.onUseToken,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isRedeemed = token.status == TokenStatus.redeemed;
    final isExpired = token.isExpired;
    final isLocked = isRedeemed || isExpired;
    final statusColor = isRedeemed
        ? AppTheme.redeemedBlue
        : (isExpired ? AppTheme.danger : AppTheme.activeGreen);
    final statusText =
        isRedeemed ? 'USED' : (isExpired ? 'EXPIRED' : 'ACTIVE');

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(AppTheme.rLg),
        border: Border.all(color: AppTheme.line),
        boxShadow: isLocked ? null : AppTheme.softShadow,
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(AppTheme.rLg),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── Status strip ────────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 12, 0),
                child: Row(
                  children: [
                    Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: statusColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: Center(
                        child: AppIcons.svg(
                          isRedeemed ? AppIcons.tokenUsed : AppIcons.pump,
                          size: 16,
                          color: statusColor,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        token.personName?.toUpperCase() ?? 'PETROL RELIEF TOKEN',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppTheme.textMid,
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                          letterSpacing: 0.6,
                        ),
                      ),
                    ),
                    _StatusBadge(label: statusText, color: statusColor),
                  ],
                ),
              ),

              // ── Token number hero ───────────────────────────────────────
              Container(
                margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                decoration: BoxDecoration(
                  color: isLocked ? AppTheme.surface : AppTheme.tint,
                  borderRadius: BorderRadius.circular(AppTheme.rMd),
                ),
                child: IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // gold edge = "this is the claimable token"
                      Container(
                        width: 5,
                        decoration: BoxDecoration(
                          color: isLocked ? AppTheme.line : AppTheme.accent,
                          borderRadius: const BorderRadius.horizontal(
                            left: Radius.circular(AppTheme.rMd),
                          ),
                        ),
                      ),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                token.subsidyAmount != null
                                    ? 'TOKEN NUMBER  ·  Rs. ${token.subsidyAmount!.toStringAsFixed(0)} RELIEF'
                                    : 'TOKEN NUMBER',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w800,
                                  color: AppTheme.textLight,
                                  letterSpacing: 1.1,
                                ),
                              ),
                              const SizedBox(height: 2),
                              FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  token.maskedTokenCode,
                                  maxLines: 1,
                                  style: TextStyle(
                                    fontSize: 30,
                                    height: 1.15,
                                    fontWeight: FontWeight.w900,
                                    color: isLocked
                                        ? Colors.grey.shade500
                                        : AppTheme.ink,
                                    letterSpacing: 1.8,
                                    decoration: isRedeemed
                                        ? TextDecoration.lineThrough
                                        : null,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Copy token and vehicle',
                        onPressed: () {
                          // Shared text must be understandable by the receiver:
                          // the token alone means nothing without its vehicle.
                          Clipboard.setData(ClipboardData(
                            text: 'Token ${token.tokenCode}'
                                ' - Vehicle ${token.vehicleNumber.toUpperCase()}',
                          ));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Token and vehicle copied!'),
                              duration: Duration(seconds: 1),
                            ),
                          );
                        },
                        icon: AppIcons.svg(AppIcons.copyToken,
                            size: 20, color: AppTheme.primary),
                      ),
                    ],
                  ),
                ),
              ),

              // ── Vehicle + countdown ─────────────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 14, 0),
                // Wrap instead of Row: the FULL vehicle number always shows;
                // the expiry pill drops to its own line when space runs out.
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    AppIcons.vehicleGlyph(token.vehicleType,
                        size: 20, color: AppTheme.textMid),
                    Text(
                      token.vehicleNumber.toUpperCase(),
                      style: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.1,
                        color: isLocked
                            ? Colors.grey.shade500
                            : AppTheme.textDark,
                      ),
                    ),
                    AppIcons.svg(AppIcons.navChevron,
                        size: 16, color: AppTheme.textLight),
                    _CountdownPill(
                      text: _expiryCountdown(token),
                      urgent: isExpired || _isUrgent(token),
                    ),
                  ],
                ),
              ),

              // ── One-time USE button / locked bar ────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                child: isRedeemed
                    ? _lockedBar(
                        AppIcons.svg(AppIcons.lock,
                            size: 16, color: AppTheme.redeemedBlue),
                        'USED — ONE-TIME ONLY, LOCKED',
                        color: AppTheme.redeemedBlue,
                      )
                    : isExpired
                        ? _lockedBar(
                            AppIcons.svg(AppIcons.deadline,
                                size: 16, color: AppTheme.danger),
                            'TOKEN EXPIRED — CANNOT BE USED',
                            color: AppTheme.danger,
                          )
                        : SizedBox(
                            height: 52,
                            child: ElevatedButton.icon(
                              onPressed: onUseToken,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppTheme.primary,
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(
                                  borderRadius:
                                      BorderRadius.circular(AppTheme.rMd),
                                ),
                              ),
                              icon: AppIcons.svg(AppIcons.stateDone,
                                  size: 20, color: AppTheme.accent),
                              label: const Text(
                                'USE TOKEN  ·  ONE-TIME',
                                style: TextStyle(
                                  fontSize: 14.5,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ),
                          ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Within 24 hours of the deadline → draw the eye.
  bool _isUrgent(TokenRecord token) {
    final e = token.expiryDate;
    if (e == null || token.isExpired) return false;
    return e.difference(DateTime.now()).inHours < 24;
  }

  /// Countdown label instead of a raw date: "Expired" / "Today · 16:47" /
  /// "3d left · 16:47", falling back to the date beyond a week.
  String _expiryCountdown(TokenRecord token) {
    final e = token.expiryDate;
    if (token.isExpired) return 'Expired';
    if (e == null) return DateFormat('dd-MMM').format(token.dateReceived);

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final expiryDay = DateTime(e.year, e.month, e.day);
    final daysLeft = expiryDay.difference(today).inDays;
    final time =
        '· ${e.hour.toString().padLeft(2, '0')}:${e.minute.toString().padLeft(2, '0')}';

    if (daysLeft <= 0) return 'Today $time';
    if (daysLeft == 1) return 'Tomorrow $time';
    if (daysLeft <= 7) return '${daysLeft}d left $time';
    return DateFormat('dd-MMM').format(e); // too far out — show the date
  }

  Widget _lockedBar(Widget icon, String text, {required Color color}) {
    return Container(
      height: 48,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppTheme.rMd),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          icon,
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w800,
                color: color,
                letterSpacing: 0.3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CountdownPill extends StatelessWidget {
  final String text;
  final bool urgent;
  const _CountdownPill({required this.text, required this.urgent});

  @override
  Widget build(BuildContext context) {
    final c = urgent ? AppTheme.danger : AppTheme.ink;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: urgent
            ? AppTheme.danger.withValues(alpha: 0.1)
            : AppTheme.accent.withValues(alpha: 0.28),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppIcons.svg(AppIcons.deadline, size: 14, color: c),
          const SizedBox(width: 5),
          Text(
            text,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              color: c,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final String label;
  final Color color;
  const _StatusBadge({required this.label, required this.color});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 10.5,
            fontWeight: FontWeight.w900,
            letterSpacing: 0.8,
          ),
        ),
      );
}
