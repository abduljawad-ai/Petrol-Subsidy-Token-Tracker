import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/token_record.dart';
import '../theme/app_graphics.dart';
import '../theme/app_theme.dart';

/// Compact row card for history / all-tokens list.
/// Supports a selection mode (long-press in History): when [selected] is
/// non-null the tile renders a checkbox + highlight and [onLongPress]
/// toggles it.
class TokenListTile extends StatelessWidget {
  final TokenRecord token;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool? selected; // null = normal mode, true/false = selection mode

  const TokenListTile({
    super.key,
    required this.token,
    this.onTap,
    this.onLongPress,
    this.selected,
  });

  @override
  Widget build(BuildContext context) {
    final statusColor = AppTheme.statusColor(token.statusLabel);
    final selectMode = selected != null;
    final isSelected = selected == true;

    Widget content = Row(
      children: [
        if (selectMode) ...[
          Checkbox(
            value: isSelected,
            onChanged: (_) => onTap?.call(),
            activeColor: AppTheme.activeGreen,
          ),
          const SizedBox(width: 6),
        ] else ...[
          // status edge bar
          Container(
            width: 4,
            height: 38,
            decoration: BoxDecoration(
              color: statusColor,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          const SizedBox(width: 12),
        ],
        // main info — the token number is the hero of the card
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Token number: own line, auto-fit. Full number always
              // readable at big print (shrinks only if a row gets truly
              // narrow, never truncated or hidden behind "…").
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  token.maskedTokenCode,
                  maxLines: 1,
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 20,
                    letterSpacing: 1,
                    color: AppTheme.ink,
                  ),
                ),
              ),
              const SizedBox(height: 2),
              Row(
                children: [
                  AppIcons.vehicleGlyph(token.vehicleType,
                      size: 14, color: AppTheme.textLight),
                  const SizedBox(width: 3),
                  Flexible(
                    child: Text(
                      token.vehicleNumber.toUpperCase(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.textMid,
                      ),
                    ),
                  ),
                  if (token.personName != null) ...[
                    const SizedBox(width: 8),
                    AppIcons.svg(AppIcons.verify, size: 13, color: AppTheme.textLight),
                    const SizedBox(width: 2),
                    Flexible(
                      child: Text(
                        token.personName!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, color: AppTheme.textLight),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        // right rail: status pill + time + date, all end-aligned and
        // grouped on the right side of the card ("proper fit")
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: statusColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                token.statusLabel == 'REDEEMED' ? 'USED' : token.statusLabel,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: statusColor,
                ),
              ),
            ),
            const SizedBox(height: 3),
            if (token.redeemedAt != null) ...[
              Text(
                DateFormat('HH:mm').format(token.redeemedAt!),
                maxLines: 1,
                overflow: TextOverflow.fade,
                style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.redeemedBlue),
              ),
              const SizedBox(height: 1),
              Text(
                DateFormat('d MMM').format(token.redeemedAt!),
                maxLines: 1,
                overflow: TextOverflow.fade,
                style: const TextStyle(fontSize: 10.5, color: AppTheme.textLight),
              ),
            ] else if (token.isExpired) ...[
              Text(
                'Expired',
                maxLines: 1,
                overflow: TextOverflow.fade,
                style: TextStyle(
                    fontSize: 11, fontWeight: FontWeight.bold, color: Colors.red.shade700),
              ),
              const SizedBox(height: 1),
              Text(
                _fmt(token.dateReceived),
                maxLines: 1,
                overflow: TextOverflow.fade,
                style: TextStyle(fontSize: 10.5, color: Colors.red.shade400),
              ),
            ] else ...[
              Text(
                _weekLabel(token.dateReceived),
                maxLines: 1,
                style: const TextStyle(
                    fontSize: 11, fontWeight: FontWeight.bold, color: AppTheme.primary),
              ),
              const SizedBox(height: 1),
              Text(
                _fmt(token.dateReceived),
                maxLines: 1,
                overflow: TextOverflow.fade,
                style: const TextStyle(fontSize: 10.5, color: AppTheme.textLight),
              ),
            ],
          ],
        ),
        const SizedBox(width: 4),
        if (!selectMode)
          AppIcons.svg(AppIcons.navChevron, size: 20, color: AppTheme.textLight),
      ],
    );

    if (selectMode) {
      content = Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppTheme.rMd),
          border: Border.all(
            color: isSelected ? AppTheme.activeGreen : Colors.transparent,
            width: 2,
          ),
        ),
        child: content,
      );
    }

    return Card(
      color: isSelected ? AppTheme.tint : null,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: content,
        ),
      ),
    );
  }

  String _fmt(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}';

  String _weekLabel(DateTime d) {
    final startOfYear = DateTime(d.year, 1, 1);
    final week = (d.difference(startOfYear).inDays / 7).floor() + 1;
    return 'W$week';
  }
}
