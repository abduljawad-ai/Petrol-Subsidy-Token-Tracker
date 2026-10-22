import 'dart:io';
import 'dart:typed_data';
import 'package:crop_your_image/crop_your_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';
import '../db/database_helper.dart';
import '../models/token_record.dart';
import '../services/ocr_service.dart';
import '../theme/app_graphics.dart';
import '../theme/app_theme.dart';
import '../widgets/token_used_overlay.dart';
import 'settings_screen.dart';

/// Scan tokens from photos — CamScanner-style flow:
///  1. Camera capture OR gallery pick (native compression already applied).
///  2. Crop view OPENS AUTOMATICALLY on the fresh photo — drag the corners,
///     hit OK. Cancel discards that photo.
///  3. The cropped photo starts reading IMMEDIATELY (own Gemini request per
///     photo — one bad photo never harms another) while the user continues.
///  4. Cards stream in; review; Save.
/// How the scan screen starts. `camera` / `gallery` open the picker the
/// instant the screen appears, so the user never needs an extra tap.
enum OcrStart { none, camera, gallery }

/// Top-level photo acquisition used OUTSIDE the scan screen (Add Token
/// sheet): pick → auto-crop → normalize. Returns null when the user
/// cancelled everything, so no extra page ever appears.
Future<List<Uint8List>?> acquireTokenPhotos(
    BuildContext context, OcrStart how) async {
  final picker = ImagePicker();
  final List<Uint8List> sources = [];
  if (how == OcrStart.camera) {
    final x = await picker.pickImage(
      source: ImageSource.camera,
      maxWidth: 1600,
      maxHeight: 1600,
      imageQuality: 88,
    );
    if (x == null) return null; // camera cancelled
    sources.add(await File(x.path).readAsBytes());
  } else if (how == OcrStart.gallery) {
    final picked = await picker.pickMultiImage(
      maxWidth: 1600,
      maxHeight: 1600,
      imageQuality: 88,
    );
    if (picked.isEmpty) return null;
    for (final p in picked) {
      sources.add(await File(p.path).readAsBytes());
    }
  }

  final out = <Uint8List>[];
  for (final b in sources) {
    if (!context.mounted) return out.isEmpty ? null : out;
    final cropped = await Navigator.of(context).push<Uint8List>(
      MaterialPageRoute(builder: (_) => TokenCropView(image: b)),
    );
    if (cropped == null) continue; // crop skipped for THIS photo only
    out.add(await normalizePhoto(cropped));
  }
  return out.isEmpty ? null : out;
}

/// Keep the upload small after cropping, in memory (no temp files).
Future<Uint8List> normalizePhoto(Uint8List cropped) async {
  try {
    final c = await FlutterImageCompress.compressWithList(
      cropped,
      minWidth: 1600,
      minHeight: 1600,
      quality: 88,
      format: CompressFormat.jpeg,
    );
    if (c.lengthInBytes > 10) return Uint8List.fromList(c);
  } catch (_) {
    // Keep the plain cropped bytes when compression is unavailable.
  }
  return cropped;
}

class OcrScanScreen extends StatefulWidget {
  final OcrStart autoStart;
  /// Already-acquired photos (from the Add Token sheet) — they skip the
  /// acquisition row and start reading immediately.
  final List<Uint8List> seedPhotos;
  const OcrScanScreen(
      {super.key, this.autoStart = OcrStart.none, this.seedPhotos = const []});

  @override
  State<OcrScanScreen> createState() => _OcrScanScreenState();
}

class _PhotoEntry {
  final Uint8List bytes; // cropped photo, held in memory (file-less flow)
  OcrImageResult? result; // null = not read yet
  bool reading = false;
  _PhotoEntry(this.bytes);
}

class _OcrScanScreenState extends State<OcrScanScreen> {
  final _db = DatabaseHelper();
  final List<_PhotoEntry> _photos = [];
  bool _saving = false;
  bool _hasKey = true;
  bool _autoStarted = false;

  @override
  void initState() {
    super.initState();
    OcrService.hasKey().then((v) async {
      if (!mounted) return;
      setState(() => _hasKey = v);
      if (widget.seedPhotos.isNotEmpty) {
        for (final b in widget.seedPhotos) {
          _addPhoto(b);
        }
        return;
      }
      if (v && !_autoStarted && widget.autoStart != OcrStart.none) {
        _autoStarted = true;
        if (widget.autoStart == OcrStart.camera) {
          await _openCamera();
        } else {
          await _openGallery();
        }
        // Cancelled with nothing taken → straight back, no dead-end screen.
        if (mounted && _photos.isEmpty) Navigator.of(context).maybePop();
      }
    });
  }

  Iterable<OcrItem> get _items => _photos
      .expand((p) => (p.result?.ok ?? false) ? p.result!.items : const <OcrItem>[]);

  int get _validCount => _items
      .where((e) =>
          !e.parsed.skip && !e.parsed.unrecognised && e.parsed.tokenCode.isNotEmpty)
      .length;

  int get _pendingCount =>
      _photos.where((p) => !p.reading && p.result == null).length;

  // ── Acquire ──────────────────────────────────────────────────────────────

  Future<void> _openCamera() async {
    if (!_hasKey) return;
    final photos = await acquireTokenPhotos(context, OcrStart.camera);
    if (photos == null) return;
    for (final b in photos) {
      _addPhoto(b);
    }
  }

  Future<void> _openGallery() async {
    if (!_hasKey) return;
    final photos = await acquireTokenPhotos(context, OcrStart.gallery);
    if (photos == null) return;
    for (final b in photos) {
      _addPhoto(b);
    }
  }

  /// In-app crop view — no native crop activity, so the plugin crash can
  /// never happen again. Opens AUTOMATICALLY on every fresh photo.
  Future<Uint8List?> _cropBytes(Uint8List src) {
    if (!mounted) return Future.value(null);
    return Navigator.of(context).push<Uint8List>(
      MaterialPageRoute(builder: (_) => TokenCropView(image: src)),
    );
  }

  Future<void> _recrop(_PhotoEntry entry) async {
    final cropped = await _cropBytes(entry.bytes);
    if (cropped == null) return;
    final i = _photos.indexOf(entry);
    if (i < 0) return;
    setState(() {
      _photos[i] = _PhotoEntry(cropped);
      _photos[i].reading = true;
    });
    _readEntry(_photos[i]);
  }

  void _remove(_PhotoEntry entry) {
    setState(() => _photos.remove(entry));
  }

  // ── Reading (each photo = its own request, running one by one) ───────────

  Future<void> _addPhoto(Uint8List bytes) async {
    final entry = _PhotoEntry(bytes);
    setState(() => _photos.add(entry));
    _readEntry(entry);
  }

  Future<void> _readEntry(_PhotoEntry entry) async {
    if (_hasKey == false) return;
    setState(() => entry.reading = true);
    final r = await OcrService.extractImage(entry.bytes, label: 'this photo');
    if (!mounted || !_photos.contains(entry)) return;
    setState(() {
      entry
        ..result = r
        ..reading = false;
      _markCrossPhotoDuplicates();
    });
  }

  /// Same token appearing in two photos (common with forwarded batches):
  /// first occurrence active, later copies auto-skipped — like the paste flow.
  void _markCrossPhotoDuplicates() {
    final seen = <String>{};
    for (final p in _photos) {
      final r = p.result;
      if (r == null || !r.ok) continue;
      for (final it in r.items) {
        final code = it.parsed.tokenCode;
        if (seen.contains(code)) {
          it.parsed
            ..skip = true
            ..dupInBatch = true;
        } else {
          seen.add(code);
        }
      }
    }
  }

  // ── Save (same rules as the paste flow) ──────────────────────────────────

  Future<void> _save() async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    setState(() => _saving = true);

    int willSave = 0;
    int candidates = 0;
    for (final e in _items) {
      if (e.parsed.skip || e.parsed.unrecognised || e.parsed.tokenCode.isEmpty) {
        continue;
      }
      candidates++;
      if (await _db.tokenCodeExists(e.parsed.tokenCode)) continue;
      willSave++;
    }

    if (willSave == 0) {
      if (mounted) setState(() => _saving = false);
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
            : 'from photo scan',
        savedCount: savedCount,
        totalCount: willSave,
        perform: () async {
          for (final e in _items) {
            if (e.parsed.skip ||
                e.parsed.unrecognised ||
                e.parsed.tokenCode.isEmpty) {
              continue;
            }
            if (await _db.tokenCodeExists(e.parsed.tokenCode)) continue;

            VehicleType vt;
            switch (e.parsed.vehicleTypeHint) {
              case 'rickshaw':
                vt = VehicleType.rickshaw;
              case 'qingqi':
                vt = VehicleType.qingqi;
              case 'smallCar':
                vt = VehicleType.smallCar;
              default:
                vt = VehicleType.motorcycle;
            }

            await _db.insertToken(TokenRecord(
              id: const Uuid().v4(),
              tokenCode: e.parsed.tokenCode,
              vehicleNumber:
                  e.parsed.vehicleNo.isEmpty ? 'UNKNOWN' : e.parsed.vehicleNo,
              vehicleType: vt,
              status: TokenStatus.active,
              dateReceived: DateTime.now(),
              dateImported: DateTime.now(),
              expiryDate: e.parsed.expiryDate,
              subsidyAmount: e.parsed.reliefAmount ?? 500.0,
              fuelLitres: vt == VehicleType.smallCar ? 30 : 20,
              originalMessage: e.parsed.rawMessage,
              notes: 'Imported via photo scan (OCR)',
            ));
            // LIVE STATUS: the center overlay's counter ticks with every
            // insert that actually lands.
            savedCount.value++;
          }
        },
      );
    } catch (err) {
      if (mounted) setState(() => _saving = false);
      messenger.showSnackBar(SnackBar(
        content: Text('Save failed: $err'),
        backgroundColor: AppTheme.danger,
        duration: const Duration(seconds: 5),
      ));
      return;
    }
    if (mounted) setState(() => _saving = false);
    navigator.pop();
  }

  // ── UI ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan SMS photo')),
      body: !_hasKey
          ? _noKeyView()
          : (_photos.isEmpty ? _captureHub() : _resultsView()),
      bottomNavigationBar:
          (_hasKey && _photos.isNotEmpty) ? _bottomBar() : null,
    );
  }

  /// Shown only when no photo is taken yet (e.g. camera was cancelled):
  /// two huge tiles that fill the screen — impossible to miss with a thumb.
  Widget _captureHub() => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          child: Column(
            children: [
              const Text(
                'Keep the SMS lines inside the frame and cut the keyboard out.',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 13.5, color: AppTheme.textMid, height: 1.4),
              ),
              const SizedBox(height: 14),
              Expanded(
                child: _BigTile(
                  filled: true,
                  asset: AppIcons.camera,
                  title: 'Take a photo',
                  subtitle: 'Open the camera',
                  onTap: _openCamera,
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: _BigTile(
                  filled: false,
                  asset: AppIcons.gallery,
                  title: 'Choose from photos',
                  subtitle: 'Pick one or many screenshots',
                  onTap: _openGallery,
                ),
              ),
            ],
          ),
        ),
      );

  Widget _resultsView() {
    final readingCount = _photos.where((p) => p.reading).length;
    final busy = readingCount > 0 || _pendingCount > 0;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      children: [
        // Plain-language status line
        Row(children: [
          if (busy)
            AppIcons.lottie(AppIcons.animAiReading, size: 20)
          else
            AppIcons.svg(AppIcons.stateDone,
                size: 20, color: AppTheme.activeGreen),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              busy
                  ? 'Reading your photo…'
                  : (_validCount > 0
                      ? '$_validCount token${_validCount == 1 ? '' : 's'} found — check, then save'
                      : 'No tokens found in this photo'),
              style: const TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w800, color: AppTheme.ink),
            ),
          ),
        ]),
        ..._resultCards(),
      ],
    );
  }

  /// Pinned thumb-zone bar: add another photo (camera / gallery) + SAVE.
  Widget _bottomBar() {
    final busy = _photos.any((p) => p.reading) || _pendingCount > 0;
    final canSave = _validCount > 0 && !_saving && !busy;
    final label = _saving
        ? 'Saving…'
        : busy
            ? 'Reading…'
            : (_validCount > 0
                ? 'Save $_validCount token${_validCount == 1 ? '' : 's'}'
                : 'Nothing to save');
    return Container(
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
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Row(
            children: [
              _SquareAction(
                asset: AppIcons.camera,
                tooltip: 'Add another photo',
                onTap: _openCamera,
              ),
              const SizedBox(width: 8),
              _SquareAction(
                asset: AppIcons.gallery,
                tooltip: 'Add from photos',
                onTap: _openGallery,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SizedBox(
                  height: 56,
                  child: ElevatedButton.icon(
                    onPressed: canSave ? _save : null,
                    icon: AppIcons.svg(AppIcons.stateDone,
                        size: 21,
                        color: canSave ? AppTheme.accent : Colors.white70),
                    label: Text(label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w800)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _noKeyView() => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppIcons.illustration('no_key', width: 200),
              const SizedBox(height: 14),
              const Text('One-time setup',
                  style: TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w900,
                      color: AppTheme.ink)),
              const SizedBox(height: 8),
              const Text(
                'Photo reading uses your own free Google Gemini key '
                '(aistudio.google.com — no credit card). Paste it in Settings once, then come back.',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 14, color: AppTheme.textMid, height: 1.5),
              ),
              const SizedBox(height: 22),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () async {
                    await Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const SettingsScreen()));
                    if (mounted) {
                      OcrService.hasKey().then((v) {
                        if (mounted) setState(() => _hasKey = v);
                      });
                    }
                  },
                  icon: AppIcons.svg(AppIcons.navSettings,
                      size: 20, color: AppTheme.accent),
                  label: const Text('Open Settings'),
                ),
              ),
            ],
          ),
        ),
      );

  /// Thumbnails row (tap = preview + re-crop) then per-photo result cards.
  List<Widget> _resultCards() {
    final widgets = <Widget>[];
    if (_photos.isNotEmpty) {
      widgets.add(const SizedBox(height: 14));
      widgets.add(SizedBox(
        height: 84,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          clipBehavior: Clip.none,
          itemCount: _photos.length,
          separatorBuilder: (_, _) => const SizedBox(width: 10),
          itemBuilder: (_, i) {
            final p = _photos[i];
            final ok = p.result?.ok ?? false;
            return Stack(
              clipBehavior: Clip.none,
              children: [
                // Tap the thumb = full preview + re-crop; re-reading starts
                // automatically after OK.
                GestureDetector(
                  onTap: p.reading ? null : () => _recrop(p),
                  child: Container(
                    width: 70,
                    height: 84,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                          color: p.reading
                              ? AppTheme.accent
                              : ok
                                  ? AppTheme.activeGreen
                                  : (p.result == null
                                      ? AppTheme.line
                                      : AppTheme.danger),
                          width: 2),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Image.memory(p.bytes,
                          fit: BoxFit.cover, width: 70, height: 84),
                    ),
                  ),
                ),
                Positioned(
                  right: -8,
                  top: -8,
                  child: Material(
                    color: Colors.white,
                    elevation: 1,
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => _remove(p),
                      child: Padding(
                        padding: const EdgeInsets.all(5),
                        child: AppIcons.svg(AppIcons.navClose,
                            size: 14, color: AppTheme.textMid),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ));
    }
    for (final p in _photos) {
      final r = p.result;
      if (p.reading || r == null) {
        widgets.add(_WaitingCard());
      } else if (r.ok) {
        for (final item in r.items) {
          widgets.add(_TokenCard(
            item: item,
            onToggle: () => setState(() => item.parsed.skip = !item.parsed.skip),
          ));
        }
      } else {
        widgets.add(_ErrorCard(
          message: r.error ?? 'Could not read.',
          onRetry: () => _readEntry(p),
        ));
      }
    }
    return widgets;
  }
}

// ── Big capture tile ─────────────────────────────────────────────────────────

class _BigTile extends StatelessWidget {
  final bool filled;
  final String asset;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  const _BigTile({
    required this.filled,
    required this.asset,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final fg = filled ? Colors.white : AppTheme.primary;
    return Material(
      color: filled ? AppTheme.primary : AppTheme.cardBg,
      borderRadius: BorderRadius.circular(AppTheme.rXl),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTheme.rXl),
        child: Container(
          width: double.infinity,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppTheme.rXl),
            border: filled
                ? null
                : Border.all(color: AppTheme.primary, width: 2),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: filled
                      ? Colors.white.withValues(alpha: 0.14)
                      : AppTheme.tint,
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: AppIcons.svg(asset,
                      size: 38, color: filled ? AppTheme.accent : AppTheme.primary),
                ),
              ),
              const SizedBox(height: 14),
              Text(title,
                  style: TextStyle(
                      fontSize: 21, fontWeight: FontWeight.w900, color: fg)),
              const SizedBox(height: 4),
              Text(subtitle,
                  style: TextStyle(
                      fontSize: 13.5, color: fg.withValues(alpha: 0.8))),
            ],
          ),
        ),
      ),
    );
  }
}

class _SquareAction extends StatelessWidget {
  final String asset;
  final String tooltip;
  final VoidCallback onTap;
  const _SquareAction(
      {required this.asset, required this.tooltip, required this.onTap});

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: Material(
          color: AppTheme.tint,
          borderRadius: BorderRadius.circular(AppTheme.rMd),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(AppTheme.rMd),
            child: SizedBox(
              width: 56,
              height: 56,
              child: Center(
                  child: AppIcons.svg(asset, size: 24, color: AppTheme.primary)),
            ),
          ),
        ),
      );
}

// ── Placeholder while a photo is queued/being read ───────────────────────────

class _WaitingCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(top: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppTheme.cardBg,
          borderRadius: BorderRadius.circular(AppTheme.rMd),
          border: Border.all(color: AppTheme.line),
        ),
        child: Row(children: [
          AppIcons.svg(AppIcons.aiReading, size: 24, color: AppTheme.primary),
          const SizedBox(width: 12),
          const Expanded(
            child: Text('Reading this photo…',
                style: TextStyle(fontSize: 14, color: AppTheme.textMid)),
          ),
        ]),
      );
}

// ── One extracted token: big number, gold flag when unsure, simple switch ────

class _TokenCard extends StatelessWidget {
  final OcrItem item;
  final VoidCallback onToggle;
  const _TokenCard({required this.item, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    final e = item.parsed;
    final flagged = item.needsCheck;
    final included = !e.skip;
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      decoration: BoxDecoration(
        color: included ? AppTheme.cardBg : AppTheme.surface,
        borderRadius: BorderRadius.circular(AppTheme.rMd),
        border: Border.all(
          color: flagged ? AppTheme.accent : AppTheme.line,
          width: flagged ? 2 : 1,
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (flagged)
                  Container(
                    margin: const EdgeInsets.only(bottom: 6),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppTheme.accent,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Text('DOUBLE-CHECK THIS NUMBER',
                        style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0.4,
                            color: AppTheme.ink)),
                  )
                else if (e.dupInBatch)
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
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    e.tokenCode,
                    maxLines: 1,
                    style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.5,
                        color: included ? AppTheme.ink : AppTheme.textLight),
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  [
                    e.vehicleNo.toUpperCase(),
                    'Rs. ${e.reliefAmount?.toInt() ?? 500}',
                    e.expiryDisplay ?? '',
                  ].where((x) => x.isNotEmpty).join('  ·  '),
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
                onChanged: (_) => onToggle(),
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
                      color: included ? AppTheme.activeGreen : AppTheme.textLight)),
            ],
          ),
        ],
      ),
    );
  }
}

// ── One failed photo: reason + retry ─────────────────────────────────────────

class _ErrorCard extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorCard({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      decoration: BoxDecoration(
        color: Colors.red.shade50,
        borderRadius: BorderRadius.circular(AppTheme.rMd),
        border: Border.all(color: AppTheme.danger.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          if (message.toLowerCase().contains('internet'))
            AppIcons.lottie(AppIcons.animNoInternet, size: 52)
          else
            AppIcons.svg(AppIcons.stateFailed, color: AppTheme.danger, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Text(message,
                style: TextStyle(
                    fontSize: 13, color: Colors.red.shade900, height: 1.35)),
          ),
          const SizedBox(width: 8),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              minimumSize: const Size(72, 44),
              padding: const EdgeInsets.symmetric(horizontal: 16),
            ),
            onPressed: onRetry,
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}

// ── In-app crop view ─────────────────────────────────────────────────────────
// Runs INSIDE Flutter (crop_your_image computes in a background isolate).
// No native crop activity and no platform result codes — the "Reply already
// submitted" crash class cannot exist here, even when the user cancels.
// Confirm / discard live in a big bottom bar (thumb zone), not the app bar.

class TokenCropView extends StatefulWidget {
  final Uint8List image;
  const TokenCropView({super.key, required this.image});

  @override
  State<TokenCropView> createState() => _CropViewState();
}

class _CropViewState extends State<TokenCropView> {
  final _controller = CropController();
  bool _working = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        automaticallyImplyLeading: false,
        title: const Text('Frame the SMS lines',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                Crop(
                  image: widget.image,
                  controller: _controller,
                  maskColor: Colors.black.withValues(alpha: 0.72),
                  onStatusChanged: (status) {
                    if (!mounted) return;
                    setState(() => _working = status == CropStatus.cropping);
                  },
                  onCropped: (CropResult result) {
                    if (!mounted) return;
                    Navigator.of(context).pop(
                        result is CropSuccess ? result.croppedImage : null);
                  },
                  progressIndicator: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(44),
                    ),
                    child: AppIcons.lottie(AppIcons.animCropBusy, size: 40),
                  ),
                ),
                if (_working)
                  Center(
                    child: Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(44),
                      ),
                      child: AppIcons.lottie(AppIcons.animCropBusy, size: 44),
                    ),
                  ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Drag the corners so only the SMS text is inside.',
                    style: TextStyle(fontSize: 13, color: Colors.white70),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      SizedBox(
                        height: 56,
                        child: OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white,
                            side: const BorderSide(color: Colors.white54),
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                          ),
                          onPressed: _working
                              ? null
                              : () => Navigator.of(context).pop(),
                          child: const Text('Discard'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: SizedBox(
                          height: 56,
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppTheme.accent,
                              foregroundColor: AppTheme.ink,
                            ),
                            onPressed:
                                _working ? null : () => _controller.crop(),
                            icon: AppIcons.svg(AppIcons.stateDone,
                                size: 22, color: AppTheme.ink),
                            label: const Text('Use this photo',
                                style: TextStyle(
                                    fontSize: 16, fontWeight: FontWeight.w900)),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
