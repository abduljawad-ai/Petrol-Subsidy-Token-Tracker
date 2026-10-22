import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';
import '../db/database_helper.dart';
import '../models/token_record.dart';
import '../services/plate_formatter.dart';
import '../theme/app_graphics.dart';
import '../theme/app_theme.dart';
import '../widgets/ft_components.dart';
import '../widgets/token_used_overlay.dart';

/// Minimal manual entry: token, vehicle number, type, amount, expiry,
/// owner name & mobile number. Status is always ACTIVE on creation —
/// this is a personal one-time-use tracker, not a bookkeeping tool.
///
/// [prefill] is used by programmatic entry flows: values start on the form but
/// the record is NEW (insert, not update) — the user verifies every digit
/// before saving.
class AddTokenScreen extends StatefulWidget {
  final TokenRecord? existing;
  final TokenRecord? prefill;
  const AddTokenScreen({super.key, this.existing, this.prefill});

  @override
  State<AddTokenScreen> createState() => _AddTokenScreenState();
}

class _AddTokenScreenState extends State<AddTokenScreen> {
  final _formKey = GlobalKey<FormState>();
  final _db = DatabaseHelper();

  late TextEditingController _tokenCodeCtrl;
  late TextEditingController _vehicleNoCtrl;
  late TextEditingController _personNameCtrl;
  late TextEditingController _mobileCtrl;
  late TextEditingController _subsidyCtrl;
  Timer? _dupDebounce;

  VehicleType _vehicleType = VehicleType.motorcycle;
  DateTime? _expiryDate;
  DateTime? _dateReceived; // preserved on edit, now() on create
  bool _saving = false;
  bool _duplicateWarning = false;

  bool get _isEditing => widget.existing != null;
  bool get _isPrefilled => !_isEditing && widget.prefill != null;

  @override
  void initState() {
    super.initState();
    final t = widget.existing ?? widget.prefill;
    _tokenCodeCtrl = TextEditingController(text: t?.tokenCode ?? '');
    _vehicleNoCtrl = TextEditingController(text: t?.vehicleNumber ?? '');
    _personNameCtrl = TextEditingController(text: t?.personName ?? '');
    _mobileCtrl = TextEditingController(text: t?.mobileNumber ?? '');
    _subsidyCtrl =
        TextEditingController(text: t?.subsidyAmount?.toStringAsFixed(0) ?? '500');
    _expiryDate = t?.expiryDate;
    _dateReceived = t?.dateReceived;
    if (t != null) {
      _vehicleType = t.vehicleType;
    }
  }

  @override
  void dispose() {
    for (final c in [_tokenCodeCtrl, _vehicleNoCtrl, _personNameCtrl, _mobileCtrl, _subsidyCtrl]) {
      c.dispose();
    }
    _dupDebounce?.cancel();
    super.dispose();
  }

  /// Debounced so typing a 10-digit code doesn't hammer the DB every keystroke.
  void _scheduleDuplicateCheck() {
    _dupDebounce?.cancel();
    _dupDebounce = Timer(const Duration(milliseconds: 350), _checkDuplicate);
  }

  Future<void> _checkDuplicate() async {
    final code = _tokenCodeCtrl.text.trim();
    if (code.isEmpty) return;
    final exists = await _db.tokenCodeExists(code, excludeId: widget.existing?.id);
    if (mounted) setState(() => _duplicateWarning = exists);
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);

    // Capture router/messenger before the async gap so the snackbar
    // survives the route pop and context use stays lint-clean.
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    final subsidyAmount = double.tryParse(_subsidyCtrl.text.trim()) ?? 500.0;
    final defaultLitres = _vehicleType == VehicleType.smallCar ? 30 : 20;

    final record = TokenRecord(
      id: widget.existing?.id ?? const Uuid().v4(),
      tokenCode: _tokenCodeCtrl.text.trim().toUpperCase(),
      vehicleNumber: _vehicleNoCtrl.text.trim().toUpperCase(),
      vehicleType: _vehicleType,
      personName: _personNameCtrl.text.trim().isEmpty ? null : _personNameCtrl.text.trim(),
      mobileNumber: _mobileCtrl.text.trim().isEmpty ? null : _mobileCtrl.text.trim(),
      cnic: null,
      status: widget.existing?.status ?? TokenStatus.active,
      dateReceived: _dateReceived ?? DateTime.now(),
      dateImported: widget.existing?.dateImported ?? DateTime.now(),
      expiryDate: _expiryDate,
      subsidyAmount: subsidyAmount,
      fuelLitres: widget.existing?.fuelLitres ?? defaultLitres,
      notes: widget.existing?.notes,
      isPotentialDuplicate: _duplicateWarning || (widget.existing?.isPotentialDuplicate ?? false),
    );

    try {
      if (_isEditing) {
        await _db.updateToken(record);
      } else {
        // Same center-screen animation as the use-token confirmation.
        await showTokenAddedConfirmation(
          context,
          title: 'Token Added',
          subtitle: record.vehicleNumber.toUpperCase(),
          code: record.tokenCode,
          perform: () => _db.insertToken(record),
        );
      }
    } catch (err) {
      // NEVER fail silently: show the real error and stay on-screen.
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Save failed: $err'),
          backgroundColor: AppTheme.danger,
          duration: const Duration(seconds: 5),
        ),
      );
      return;
    }

    navigator.pop(true);
    if (_isEditing) {
      messenger.showSnackBar(
        SnackBar(
          content: const Text('Token updated!'),
          backgroundColor: AppTheme.activeGreen,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasOptional = _personNameCtrl.text.trim().isNotEmpty ||
        _mobileCtrl.text.trim().isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing
            ? 'Edit token'
            : _isPrefilled
                ? 'Check & save'
                : 'New token'),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
          children: [
            if (_isPrefilled)
              _InfoBanner(
                icon: AppIcons.crop,
                text: 'Filled from your scan. Check every digit before saving.',
                color: AppTheme.primary,
                background: AppTheme.tint,
              ),
            if (_duplicateWarning)
              _InfoBanner(
                icon: AppIcons.stateDoubt,
                text: 'A token with this number already exists. Please check before saving.',
                color: AppTheme.ink,
                background: AppTheme.accent.withValues(alpha: 0.3),
              ),

            // ── 1 · Token number (the whole point of the app) ───────────────
            const _StepLabel(1, 'Token number'),
            TextFormField(
              controller: _tokenCodeCtrl,
              keyboardType: TextInputType.number,
              inputFormatters: <TextInputFormatter>[
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(14),
              ],
              decoration: InputDecoration(
                hintText: '8401712225',
                prefixIcon: Padding(
                  padding: const EdgeInsets.all(14),
                  child: AppIcons.svg(AppIcons.tokenCard,
                      size: 22, color: AppTheme.primary),
                ),
              ),
              style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 2,
                  color: AppTheme.ink),
              validator: (v) => (v == null || v.trim().isEmpty)
                  ? 'Enter the token number'
                  : null,
              onChanged: (_) => _scheduleDuplicateCheck(),
            ),

            // ── 2 · Vehicle ─────────────────────────────────────────────────
            const _StepLabel(2, 'Vehicle'),
            TextFormField(
              controller: _vehicleNoCtrl,
              textCapitalization: TextCapitalization.characters,
              inputFormatters: <TextInputFormatter>[
                PlateInputFormatter(),
              ],
              decoration: InputDecoration(
                hintText: 'NFF-2364',
                prefixIcon: Padding(
                  padding: const EdgeInsets.all(14),
                  child: AppIcons.vehicleGlyph(_vehicleType,
                      size: 22, color: AppTheme.primary),
                ),
              ),
              style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2,
                  color: AppTheme.ink),
              validator: (v) => (v == null || v.trim().isEmpty)
                  ? 'Enter the vehicle number'
                  : null,
            ),
            const SizedBox(height: 12),
            GridView.count(
              crossAxisCount: 3,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 1.45,
              children: VehicleType.values.map((vt) {
                const labels = [
                  'Motorcycle', 'Rickshaw', 'Qingqi', 'Small car', 'Other'
                ];
                return _VehicleTile(
                  type: vt,
                  label: labels[vt.index],
                  selected: _vehicleType == vt,
                  onTap: () => setState(() => _vehicleType = vt),
                );
              }).toList(),
            ),

            // ── 3 · Relief and deadline ─────────────────────────────────────
            const _StepLabel(3, 'Relief and deadline'),
            TextFormField(
              controller: _subsidyCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: 'Relief amount (Rs.)',
                hintText: '500',
                prefixIcon: Padding(
                  padding: const EdgeInsets.all(14),
                  child: AppIcons.svg(AppIcons.rupee,
                      size: 20, color: AppTheme.primary),
                ),
              ),
              style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: AppTheme.ink),
            ),
            const SizedBox(height: 12),
            _DeadlineTile(
              value: _expiryDate == null ? null : _fmtExpiry(_expiryDate!),
              onTap: _pickExpiry,
              onClear: _expiryDate == null
                  ? null
                  : () => setState(() => _expiryDate = null),
            ),

            // ── Optional extras, tucked away ────────────────────────────────
            const SizedBox(height: 16),
            Container(
              decoration: BoxDecoration(
                color: AppTheme.cardBg,
                borderRadius: BorderRadius.circular(AppTheme.rMd),
                border: Border.all(color: AppTheme.line),
              ),
              child: Theme(
                data: Theme.of(context)
                    .copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  initiallyExpanded: hasOptional,
                  tilePadding: const EdgeInsets.symmetric(horizontal: 16),
                  childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  title: const Text('More details (optional)',
                      style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 14.5,
                          color: AppTheme.ink)),
                  children: [
                    TextFormField(
                      controller: _personNameCtrl,
                      textCapitalization: TextCapitalization.words,
                      decoration: InputDecoration(
                        labelText: 'Owner name',
                        prefixIcon: Padding(
                          padding: const EdgeInsets.all(14),
                          child: AppIcons.svg(AppIcons.verify,
                              size: 20, color: AppTheme.textMid),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _mobileCtrl,
                      keyboardType: TextInputType.phone,
                      decoration: InputDecoration(
                        labelText: 'Mobile number',
                        hintText: '03XX-XXXXXXX',
                        prefixIcon: Padding(
                          padding: const EdgeInsets.all(14),
                          child: AppIcons.svg(AppIcons.hardwarePhone,
                              size: 20, color: AppTheme.textMid),
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
      bottomNavigationBar: FtBottomBar(
        child: FtPrimaryButton(
          label: _isEditing ? 'Update token' : 'Save token',
          iconAsset: AppIcons.saveToken,
          busy: _saving,
          onPressed: _save,
        ),
      ),
    );
  }

  Future<void> _pickExpiry() async {
    final initial = _expiryDate ?? DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2023),
      lastDate: DateTime(2100),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    final tod = time ?? TimeOfDay.fromDateTime(initial);
    setState(() {
      _expiryDate = DateTime(date.year, date.month, date.day, tod.hour, tod.minute);
    });
  }

  String _fmtExpiry(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}-${_monthAbbr(d.month)}-${d.year} · '
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  String _monthAbbr(int m) => const [
        '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
      ][m];
}


class _StepLabel extends StatelessWidget {
  final int n;
  final String text;
  const _StepLabel(this.n, this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(2, 20, 0, 10),
        child: Row(
          children: [
            Container(
              width: 24,
              height: 24,
              decoration: const BoxDecoration(
                color: AppTheme.accent,
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Text('$n',
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w900,
                        color: AppTheme.ink)),
              ),
            ),
            const SizedBox(width: 10),
            Text(text,
                style: const TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w900,
                    color: AppTheme.ink)),
          ],
        ),
      );
}

class _VehicleTile extends StatelessWidget {
  final VehicleType type;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _VehicleTile({
    required this.type,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => Material(
        color: selected ? AppTheme.primary : AppTheme.cardBg,
        borderRadius: BorderRadius.circular(AppTheme.rMd),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppTheme.rMd),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppTheme.rMd),
              border: Border.all(
                color: selected ? AppTheme.primary : AppTheme.line,
                width: 1.4,
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AppIcons.vehicleGlyph(type,
                    size: 26,
                    color: selected ? AppTheme.accent : AppTheme.textMid),
                const SizedBox(height: 4),
                Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: selected ? Colors.white : AppTheme.ink)),
              ],
            ),
          ),
        ),
      );
}

class _DeadlineTile extends StatelessWidget {
  final String? value;
  final VoidCallback onTap;
  final VoidCallback? onClear;
  const _DeadlineTile(
      {required this.value, required this.onTap, required this.onClear});

  @override
  Widget build(BuildContext context) => Material(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(AppTheme.rMd),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppTheme.rMd),
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppTheme.rMd),
              border: Border.all(color: AppTheme.line),
            ),
            child: Row(
              children: [
                AppIcons.svg(AppIcons.deadline,
                    size: 22, color: AppTheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        value == null ? 'Set deadline' : 'Valid until',
                        style: const TextStyle(
                            fontSize: 12, color: AppTheme.textLight),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        value ?? 'Tap to pick date and time',
                        style: TextStyle(
                          fontSize: value == null ? 14 : 16,
                          fontWeight: FontWeight.w800,
                          color: value == null ? AppTheme.textMid : AppTheme.ink,
                        ),
                      ),
                    ],
                  ),
                ),
                if (onClear != null)
                  IconButton(
                    tooltip: 'Clear deadline',
                    icon: AppIcons.svg(AppIcons.navClose,
                        size: 18, color: AppTheme.textMid),
                    onPressed: onClear,
                  )
                else
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: AppIcons.svg(AppIcons.navChevron,
                        size: 20, color: AppTheme.primary),
                  ),
              ],
            ),
          ),
        ),
      );
}

class _InfoBanner extends StatelessWidget {
  final String icon;
  final String text;
  final Color color;
  final Color background;
  const _InfoBanner({
    required this.icon,
    required this.text,
    required this.color,
    required this.background,
  });

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(AppTheme.rMd),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppIcons.svg(icon, size: 20, color: color),
            const SizedBox(width: 10),
            Expanded(
              child: Text(text,
                  style: TextStyle(
                      color: color,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      height: 1.35)),
            ),
          ],
        ),
      );
}
