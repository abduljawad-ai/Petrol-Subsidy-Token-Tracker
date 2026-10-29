import 'package:flutter/material.dart';
import '../theme/app_graphics.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../db/database_helper.dart';
import '../models/token_record.dart';
import '../theme/app_theme.dart';
import '../widgets/ft_components.dart';
import '../widgets/token_used_overlay.dart';
import 'add_token_screen.dart';

/// Token detail (v2): built to be SHOWN to the pump attendant.
/// Big readable ticket on top, the one-time USE button pinned at the bottom
/// (thumb zone), everything else below the fold.
class TokenDetailScreen extends StatefulWidget {
  final TokenRecord token;
  const TokenDetailScreen({super.key, required this.token});

  @override
  State<TokenDetailScreen> createState() => _TokenDetailScreenState();
}

class _TokenDetailScreenState extends State<TokenDetailScreen> {
  late TokenRecord _token;
  final _db = DatabaseHelper();

  @override
  void initState() {
    super.initState();
    _token = widget.token;
  }

  void _toast(String text, {Color? color}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        backgroundColor: color,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  // ── CONFIRM ONE-TIME USE ─────────────────────────────────────────────────
  Future<void> _promptUseToken() async {
    if (_token.status == TokenStatus.redeemed) {
      _toast('Already used. Cannot reuse.', color: AppTheme.pendingOrange);
      return;
    }
    if (_token.isExpired) {
      _toast('This token has expired and cannot be used.',
          color: AppTheme.danger);
      return;
    }

    final confirmed = await showFtUseTokenDialog(context, _token);
    if (!mounted || !confirmed) return;

    try {
      // Same center-screen celebration as the Home flow.
      await showTokenUsedConfirmation(
        context,
        vehicleNumber: _token.vehicleNumber.toUpperCase(),
        tokenCode: _token.tokenCode,
        perform: () => _db.markRedeemed(_token.id),
      );
      final updated = await _db.getTokenById(_token.id);
      if (!mounted) return;
      setState(() {
        if (updated != null) {
          _token = updated;
        } else {
          _token = _token.copyWith(status: TokenStatus.redeemed);
        }
      });
    } catch (err) {
      if (mounted) _toast('Could not mark used: $err', color: AppTheme.danger);
    }
  }

  Future<void> _delete() async {
    final confirm = await showFtConfirm(
      context,
      title: 'Delete this token?',
      message: 'It will be removed from this phone. You get one UNDO right after.',
      confirmLabel: 'Delete',
      cancelLabel: 'Keep',
      danger: true,
    );
    if (!confirm) return;
    if (!mounted) return;
    try {
      await showTokenDeletedConfirmation(
        context,
        title: 'Token Deleted',
        subtitle: _token.vehicleNumber.toUpperCase(),
        code: _token.tokenCode,
        perform: () => _db.deleteToken(_token.id),
        onUndo: () => _db.insertToken(_token),
      );
    } catch (err) {
      if (mounted) _toast('Delete failed: $err', color: AppTheme.danger);
      return;
    }
    if (mounted) Navigator.pop(context);
  }

  Future<void> _edit() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => AddTokenScreen(existing: _token)),
    );
    // Re-read by id (vehicle number may have changed during edit)
    final updated = await _db.getTokenById(_token.id);
    if (updated != null && mounted) setState(() => _token = updated);
  }

  void _copyBoth() {
    // Shared text must be understandable by the receiver:
    // the token alone means nothing without its vehicle.
    Clipboard.setData(ClipboardData(
      text: 'Token ${_token.tokenCode}'
          ' - Vehicle ${_token.vehicleNumber.toUpperCase()}',
    ));
    _toast('Token and vehicle copied!');
  }

  // ── BUILD ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isRedeemed = _token.status == TokenStatus.redeemed;
    final isExpired = _token.isExpired && !isRedeemed;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Token'),
        actions: [
          IconButton(
            tooltip: 'Edit',
            icon: AppIcons.svg(AppIcons.editToken, size: 22, color: Colors.white),
            onPressed: _edit,
          ),
          IconButton(
            tooltip: 'Delete',
            icon: AppIcons.svg(AppIcons.deleteToken, size: 22, color: Colors.white),
            onPressed: _delete,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          _ticket(isRedeemed, isExpired),
          _detailsCard(),
          if (_token.originalMessage != null)
            _SmsCard(message: _token.originalMessage!),
        ],
      ),
      bottomNavigationBar: _bottom(isRedeemed, isExpired),
    );
  }

  Widget _ticket(bool isRedeemed, bool isExpired) {
    final Color state = isRedeemed
        ? AppTheme.redeemedBlue
        : (isExpired ? AppTheme.danger : AppTheme.primary);
    final String banner = isRedeemed
        ? 'USED  ·  LOCKED'
        : (isExpired ? 'EXPIRED' : 'SHOW THIS AT THE PUMP');
    final locked = isRedeemed || isExpired;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      decoration: BoxDecoration(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(AppTheme.rXl),
        border: Border.all(color: state, width: 2),
        boxShadow: locked ? null : AppTheme.softShadow,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppTheme.rXl - 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // State banner
            Container(
              color: state,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
              child: Row(
                children: [
                  AppIcons.svg(
                    isRedeemed
                        ? AppIcons.lock
                        : (isExpired ? AppIcons.deadline : AppIcons.pump),
                    size: 18,
                    color: Colors.white,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      banner,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                        fontSize: 13,
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                  if (_token.subsidyAmount != null)
                    Text(
                      'Rs. ${_token.subsidyAmount!.toStringAsFixed(0)}',
                      style: const TextStyle(
                        color: AppTheme.accent,
                        fontWeight: FontWeight.w900,
                        fontSize: 16,
                      ),
                    ),
                ],
              ),
            ),

            // Vehicle
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: AppTheme.tint,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Center(
                      child: AppIcons.vehicleGlyph(_token.vehicleType,
                          size: 26, color: AppTheme.primary),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('VEHICLE',
                            style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w800,
                                color: AppTheme.textLight,
                                letterSpacing: 1.2)),
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: Text(
                            _token.vehicleNumber.toUpperCase(),
                            maxLines: 1,
                            style: TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 2,
                              color: locked ? AppTheme.textLight : AppTheme.ink,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // Tear line
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: List.generate(
                  26,
                  (_) => Container(width: 6, height: 2, color: AppTheme.line),
                ),
              ),
            ),

            // Token number (hero) — gold edge is a real child, not a border,
            // so the rounded corners stay valid.
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 14),
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: locked ? AppTheme.surface : AppTheme.tint,
                borderRadius: BorderRadius.circular(AppTheme.rLg),
              ),
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      width: 6,
                      color: locked ? AppTheme.line : AppTheme.accent,
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('TOKEN NUMBER',
                                style: TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w800,
                                    color: AppTheme.textLight,
                                    letterSpacing: 1.2)),
                            const SizedBox(height: 4),
                            SizedBox(
                              width: double.infinity,
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  _token.tokenCode,
                                  maxLines: 1,
                                  style: TextStyle(
                                    fontSize: 40,
                                    height: 1.1,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 3,
                                    color: locked
                                        ? Colors.grey.shade500
                                        : AppTheme.ink,
                                    decoration: isRedeemed
                                        ? TextDecoration.lineThrough
                                        : null,
                                  ),
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

            // Facts row
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 0),
              child: Row(
                children: [
                  Expanded(
                    child: _Fact(
                      icon: AppIcons.deadline,
                      label: isRedeemed ? 'USED AT' : 'DEADLINE',
                      value: isRedeemed && _token.redeemedAt != null
                          ? DateFormat('d MMM · HH:mm').format(_token.redeemedAt!)
                          : ftDeadlineLabel(_token),
                      color: isExpired ? AppTheme.danger : AppTheme.ink,
                    ),
                  ),
                  if (_token.fuelLitres != null) ...[
                    const SizedBox(width: 10),
                    Expanded(
                      child: _Fact(
                        icon: AppIcons.litres,
                        label: 'QUOTA',
                        value: '${_token.fuelLitres} L',
                        color: AppTheme.ink,
                      ),
                    ),
                  ],
                ],
              ),
            ),

            // Copy
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 16),
              child: SizedBox(
                height: 48,
                child: OutlinedButton.icon(
                  onPressed: _copyBoth,
                  icon: AppIcons.svg(AppIcons.copyToken,
                      size: 19, color: AppTheme.primary),
                  label: const Text('Copy token + vehicle'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bottom(bool isRedeemed, bool isExpired) {
    if (isRedeemed) {
      return FtBottomBar(
        child: _StatusStrip(
          icon: AppIcons.lock,
          text: 'Used — one-time only, locked',
          color: AppTheme.redeemedBlue,
        ),
      );
    }
    if (isExpired) {
      return FtBottomBar(
        child: _StatusStrip(
          icon: AppIcons.deadline,
          text: 'Expired — cannot be used',
          color: AppTheme.danger,
        ),
      );
    }
    return FtBottomBar(
      child: FtPrimaryButton(
        label: 'Use token at pump',
        iconAsset: AppIcons.stateDone,
        onPressed: _promptUseToken,
      ),
    );
  }

  Widget _detailsCard() {
    final t = _token;
    final rows = <_Row>[
      _Row(AppIcons.navTokens, 'Vehicle type', t.vehicleTypeLabel),
      if (t.personName != null) _Row(AppIcons.verify, 'Owner', t.personName!),
      if (t.cnic != null && t.cnic!.isNotEmpty)
        _Row(AppIcons.lock, 'CNIC', t.cnic!),
      if (t.mobileNumber != null)
        _Row(AppIcons.hardwarePhone, 'Mobile', t.mobileNumber!),
      if (t.subsidyAmount != null)
        _Row(AppIcons.rupee, 'Relief', 'Rs. ${t.subsidyAmount!.toStringAsFixed(0)}'),
      if (t.expiryDate != null)
        _Row(AppIcons.deadline, 'Valid until',
            DateFormat('dd MMM yyyy, HH:mm').format(t.expiryDate!)),
      if (t.redeemedAt != null)
        _Row(AppIcons.tokenUsed, 'Used at',
            DateFormat('dd MMM yyyy, HH:mm').format(t.redeemedAt!)),
      _Row(AppIcons.sms, 'Received',
          DateFormat('dd MMM yyyy').format(t.dateReceived)),
      if (t.notes != null && t.notes!.isNotEmpty)
        _Row(AppIcons.editToken, 'Notes', t.notes!),
    ];
    return FtSurface(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Details',
              style: TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w900, color: AppTheme.ink)),
          const SizedBox(height: 8),
          for (final r in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppIcons.svg(r.icon, size: 18, color: AppTheme.textLight),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 92,
                    child: Text(r.label,
                        style: const TextStyle(
                            color: AppTheme.textLight, fontSize: 13.5)),
                  ),
                  Expanded(
                    child: Text(r.value,
                        style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 13.5,
                            color: AppTheme.ink)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _Row {
  final String icon;
  final String label;
  final String value;
  const _Row(this.icon, this.label, this.value);
}

class _Fact extends StatelessWidget {
  final String icon;
  final String label;
  final String value;
  final Color color;
  const _Fact({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(AppTheme.rMd),
        ),
        child: Row(
          children: [
            AppIcons.svg(icon, size: 20, color: color),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          color: AppTheme.textLight,
                          letterSpacing: 0.9)),
                  const SizedBox(height: 2),
                  Text(value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w800,
                          color: color)),
                ],
              ),
            ),
          ],
        ),
      );
}

class _StatusStrip extends StatelessWidget {
  final String icon;
  final String text;
  final Color color;
  const _StatusStrip(
      {required this.icon, required this.text, required this.color});

  @override
  Widget build(BuildContext context) => Container(
        height: 56,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(AppTheme.rMd),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AppIcons.svg(icon, size: 20, color: color),
            const SizedBox(width: 10),
            Flexible(
              child: Text(text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 14.5, fontWeight: FontWeight.w800, color: color)),
            ),
          ],
        ),
      );
}

class _SmsCard extends StatelessWidget {
  final String message;
  const _SmsCard({required this.message});

  @override
  Widget build(BuildContext context) => FtSurface(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                AppIcons.svg(AppIcons.sms, size: 18, color: AppTheme.textMid),
                const SizedBox(width: 8),
                const Text('Original 9771 SMS',
                    style: TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 15,
                        color: AppTheme.ink)),
              ],
            ),
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppTheme.surface,
                borderRadius: BorderRadius.circular(AppTheme.rMd),
              ),
              child: Text(
                message,
                style: const TextStyle(
                    fontSize: 13.5, height: 1.55, color: AppTheme.textMid),
              ),
            ),
          ],
        ),
      );
}
