import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_graphics.dart';
import 'package:uuid/uuid.dart';
import '../db/database_helper.dart';
import '../models/token_record.dart';
import '../services/sms_parser.dart';
import '../theme/app_theme.dart';
import '../widgets/ft_components.dart';
import '../widgets/token_used_overlay.dart';

/// Screen to paste raw SMS text and extract token info automatically.
/// Supports official 9771 Pakistan Petrol Subsidy SMS formats in both Urdu and English.
class PasteSmsScreen extends StatefulWidget {
  const PasteSmsScreen({super.key});

  @override
  State<PasteSmsScreen> createState() => _PasteSmsScreenState();
}

class _PasteSmsScreenState extends State<PasteSmsScreen> {
  final _ctrl = TextEditingController();
  final _db = DatabaseHelper();
  List<ExtractedSmsToken> _extracted = [];
  bool _processed = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    // Nothing reads the clipboard on its own. The text only arrives when
    // the user taps the paste button (or types/pastes by hand).
  }

  /// Big "Paste" button: fill from clipboard and read in one tap.
  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (!mounted) return;
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Clipboard is empty. Copy the 9771 SMS first.'),
      ));
      return;
    }
    _ctrl.text = text;
    _processMessages();
  }

  int get _savableCount => _extracted
      .where((e) => !e.skip && !e.unrecognised && e.tokenCode.isNotEmpty)
      .length;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _processMessages() {
    final text = _ctrl.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _extracted = SmsParser.parse(text);
      _processed = true;
    });
  }

  Future<void> _saveAll() async {
    setState(() => _saving = true);

    // Capture messenger BEFORE popping so the snackbar survives the route pop.
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    // Pre-count what will be saved so the confirmation shows real numbers
    // (fast reads, no writes; the save loop below re-checks before inserting).
    int willSave = 0;
    int candidates = 0;
    for (final e in _extracted) {
      if (e.skip || e.unrecognised || e.tokenCode.isEmpty) continue;
      candidates++;
      if (await _db.tokenCodeExists(e.tokenCode)) continue;
      willSave++;
    }

    if (willSave == 0) {
      navigator.pop();
      messenger.showSnackBar(const SnackBar(
        content: Text('Nothing new to save — all tokens already exist.'),
        backgroundColor: AppTheme.activeGreen,
      ));
      return;
    }

    final skippedDupes = candidates - willSave;
    if (!mounted) return;

    final savedCount = ValueNotifier<int>(0);

    try {
      await showTokenAddedConfirmation(
        context,
        title: '$willSave Token${willSave == 1 ? '' : 's'} Added',
        subtitle: skippedDupes > 0
            ? '$skippedDupes duplicate${skippedDupes == 1 ? '' : 's'} skipped'
            : 'from pasted 9771 SMS',
        savedCount: savedCount,
        totalCount: willSave,
        perform: () async {
          for (final e in _extracted) {
            if (e.skip || e.unrecognised || e.tokenCode.isEmpty) continue;

            // DEDUPE GUARD: never import the same token code twice.
            if (await _db.tokenCodeExists(e.tokenCode)) continue;

            // Vehicle type: use the SMS's own wording when it names the vehicle
            // (Pakistani plates do NOT encode type). Default = motorcycle, the
            // scheme's primary audience, when nothing is stated.
            VehicleType vt;
            switch (e.vehicleTypeHint) {
              case 'rickshaw':
                vt = VehicleType.rickshaw;
              case 'qingqi':
                vt = VehicleType.qingqi;
              case 'smallCar':
                vt = VehicleType.smallCar;
              default:
                vt = VehicleType.motorcycle;
            }

            final record = TokenRecord(
              id: const Uuid().v4(),
              tokenCode: e.tokenCode,
              vehicleNumber: e.vehicleNo.isEmpty ? 'UNKNOWN' : e.vehicleNo,
              vehicleType: vt,
              status: TokenStatus.active,
              dateReceived: DateTime.now(),
              dateImported: DateTime.now(),
              expiryDate: e.expiryDate,
              subsidyAmount: e.reliefAmount ?? 500.0,
              fuelLitres: vt == VehicleType.smallCar ? 30 : 20,
              originalMessage: e.rawMessage,
              notes: 'Imported via 9771 SMS auto-extractor',
            );
            await _db.insertToken(record);
            // LIVE STATUS: the center overlay's counter ticks with every
            // insert that actually lands.
            savedCount.value++;
          }
        },
      );
    } catch (err) {
      // NEVER fail silently: show the real database error and stay on-screen.
      if (mounted) setState(() => _saving = false);
      messenger.showSnackBar(
        SnackBar(
          content: Text('Save failed: $err'),
          backgroundColor: AppTheme.danger,
          duration: const Duration(seconds: 5),
        ),
      );
      return;
    }

    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Paste 9771 SMS')),
      body: _processed ? _resultsView() : _inputView(),
      bottomNavigationBar: FtBottomBar(
        child: !_processed
            ? FtPrimaryButton(
                label: 'Read tokens',
                iconAsset: AppIcons.aiReading,
                onPressed: _processMessages,
              )
            : Row(
                children: [
                  SizedBox(
                    height: 56,
                    child: OutlinedButton(
                      onPressed: () => setState(() {
                        _processed = false;
                        _extracted = [];
                      }),
                      child: const Text('Back'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FtPrimaryButton(
                      label: _saving
                          ? 'Saving…'
                          : (_savableCount > 0
                              ? 'Save $_savableCount token${_savableCount == 1 ? '' : 's'}'
                              : 'Nothing to save'),
                      iconAsset: AppIcons.stateDone,
                      busy: _saving,
                      onPressed: _savableCount > 0 ? _saveAll : null,
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _inputView() => ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        children: [
          // One tap: paste + read.
          SizedBox(
            height: 64,
            child: ElevatedButton.icon(
              onPressed: _pasteFromClipboard,
              icon: AppIcons.svg(AppIcons.paste, size: 24, color: AppTheme.accent),
              label: const Text('Paste from clipboard',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
            ),
          ),
          const SizedBox(height: 8),
          const Center(
            child: Text(
              'Copy the SMS from 9771 first, then tap the button.',
              style: TextStyle(fontSize: 12.5, color: AppTheme.textLight),
            ),
          ),
          const SizedBox(height: 20),
          const Text('Or type / paste here',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: AppTheme.textMid)),
          const SizedBox(height: 8),
          TextField(
            controller: _ctrl,
            minLines: 5,
            maxLines: 12,
            textAlignVertical: TextAlignVertical.top,
            keyboardType: TextInputType.multiline,
            decoration: const InputDecoration(
              hintText: 'Paste the SMS here (Urdu or English)',
            ),
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppIcons.svg(AppIcons.aiReading, size: 16, color: AppTheme.textLight),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Token, vehicle, amount and deadline are found for you. Duplicates are skipped.',
                  style: TextStyle(
                      fontSize: 12.5, color: AppTheme.textLight, height: 1.4),
                ),
              ),
            ],
          ),
        ],
      );

  Widget _resultsView() {
    final found = _extracted.where((e) => !e.unrecognised).length;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      children: [
        Row(
          children: [
            AppIcons.svg(
              found > 0 ? AppIcons.stateDone : AppIcons.stateDoubt,
              size: 22,
              color: found > 0 ? AppTheme.activeGreen : AppTheme.ink,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                found > 0
                    ? '$found token${found == 1 ? '' : 's'} found, check then save'
                    : 'No tokens found in this text',
                style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 16,
                    color: AppTheme.ink),
              ),
            ),
            TextButton(
              onPressed: () => setState(() {
                _processed = false;
                _extracted = [];
              }),
              child: const Text('Edit text'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ..._extracted.map((item) => _ExtractedCard(
              item: item,
              onSkipChanged: (v) => setState(() => item.skip = v ?? false),
            )),
      ],
    );
  }
}

class _ExtractedCard extends StatelessWidget {
  final ExtractedSmsToken item;
  final ValueChanged<bool?> onSkipChanged;
  const _ExtractedCard({required this.item, required this.onSkipChanged});

  @override
  Widget build(BuildContext context) {
    if (item.unrecognised) {
      return Container(
        margin: const EdgeInsets.only(top: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppTheme.accent.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(AppTheme.rMd),
          border: Border.all(color: AppTheme.accent, width: 1.5),
        ),
        child: Row(
          children: [
            AppIcons.svg(AppIcons.help, size: 20, color: AppTheme.ink),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                'Could not read a token from one part of the text. It will not be saved.',
                style: TextStyle(fontSize: 13, color: AppTheme.ink, height: 1.35),
              ),
            ),
          ],
        ),
      );
    }

    final included = !item.skip;
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      decoration: BoxDecoration(
        color: included ? AppTheme.cardBg : AppTheme.surface,
        borderRadius: BorderRadius.circular(AppTheme.rMd),
        border: Border.all(color: AppTheme.line),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (item.dupInBatch)
                  Container(
                    margin: const EdgeInsets.only(bottom: 6),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppTheme.line,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Text('DUPLICATE — NOT SAVED',
                        style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w900,
                            color: AppTheme.textMid)),
                  ),
                // The one number that matters, big and readable.
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    item.tokenCode,
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1.5,
                      color: included ? AppTheme.ink : AppTheme.textLight,
                    ),
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  [
                    if (item.vehicleNo.isNotEmpty) item.vehicleNo.toUpperCase(),
                    if (item.reliefAmount != null)
                      'Rs. ${item.reliefAmount!.toStringAsFixed(0)}',
                    if (item.expiryDisplay != null) item.expiryDisplay!,
                  ].join('  ·  '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textMid),
                ),
              ],
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Switch(
                value: included,
                onChanged: (v) => onSkipChanged(!v),
                thumbColor: const WidgetStatePropertyAll(Colors.white),
                trackColor: WidgetStateProperty.resolveWith((states) =>
                    states.contains(WidgetState.selected)
                        ? AppTheme.activeGreen
                        : AppTheme.line),
              ),
              Text(included ? 'Save' : 'Skip',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color:
                          included ? AppTheme.activeGreen : AppTheme.textLight)),
            ],
          ),
        ],
      ),
    );
  }
}
