
import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';
import 'package:flutter/scheduler.dart';

import '../theme/app_theme.dart';

/// Center-screen animated confirmation shared by every token action
/// (used / added / deleted). Replaces the old bottom snackbars.
///
/// Staged animation:
///
///   BUSY  – ring spinner while the work ([perform]) runs (min 650 ms so the
///           motion reads, even on instant writes)
///   DONE  – ring sweeps shut, a check-mark traces itself, the title pops in,
///           holds, then the overlay fades out
///
/// If [perform] throws, the overlay closes immediately and RE-THROWS so
/// the caller's existing error handling can surface the real message.
/// Tapping the card once DONE finishes skips the hold.
///
/// UNDO: when [onUndo] is provided (delete flows), a chip stays inside the
/// card for the whole ~4 s hold — tapping it runs the restore and closes,
/// exactly like the old UNDO snackbar.
Future<void> showTokenActionConfirmation(
  BuildContext context, {
  required String title,
  required String busyLabel,
  required Future<void> Function() perform,
  String? subtitle,
  String? code,
  String? footnote,
  Duration? hold,
  Future<void> Function()? onUndo,
  /// LIVE STATUS: batch adds push the real insert count in here while
  /// [perform] runs — the busy line shows "label · n of m" ticking live,
  /// and [doneTitleFor] (if given) rebuilds the done title from the FINAL
  /// real count, so the overlay can never claim more than actually saved.
  ValueNotifier<int>? progress,
  int? progressTotal,
  String Function(int realCount)? doneTitleFor,
}) async {
  final carried = await showGeneralDialog<Object?>(
    context: context,
    barrierColor: Colors.black54,
    barrierDismissible: false,
    transitionDuration: const Duration(milliseconds: 180),
    barrierLabel: 'token-action',
    pageBuilder: (ctx, a1, a2) => _TokenConfirmView(
      title: title,
      busyLabel: busyLabel,
      subtitle: subtitle,
      code: code,
      footnote: footnote,
      hold: hold ?? const Duration(milliseconds: 900),
      onUndo: onUndo,
      perform: perform,
      progress: progress,
      progressTotal: progressTotal,
      doneTitleFor: doneTitleFor,
    ),
    transitionBuilder: (ctx, anim, _, child) => FadeTransition(opacity: anim, child: child),
  );
  if (carried != null) {
    // Re-surface the real DB error to the caller's catch block.
    throw carried;
  }
}

/// Used at the pump — keeps the original call signature.
Future<void> showTokenUsedConfirmation(
  BuildContext context, {
  required Future<void> Function() perform,
  required String vehicleNumber,
  String? tokenCode,
}) =>
    showTokenActionConfirmation(
      context,
      title: 'Token Used',
      busyLabel: 'Locking token…',
      subtitle: vehicleNumber.toUpperCase(),
      code: tokenCode,
      footnote: 'one-time use · locked against re-use',
      perform: perform,
    );

/// New token saved. For batch adds, pass [savedCount]/[totalCount] to get a
/// live "n of m" counter while inserts run, and the done title built from
/// the REAL saved count.
Future<void> showTokenAddedConfirmation(
  BuildContext context, {
  required Future<void> Function() perform,
  required String title,
  String? subtitle,
  String? code,
  String? footnote,
  ValueNotifier<int>? savedCount,
  int? totalCount,
}) =>
    showTokenActionConfirmation(
      context,
      title: title,
      busyLabel: 'Saving token…',
      subtitle: subtitle,
      code: code,
      footnote: footnote ?? 'stored on this phone · backed up automatically',
      perform: perform,
      progress: savedCount,
      progressTotal: totalCount,
      doneTitleFor: savedCount != null
          ? (n) => '$n Token${n == 1 ? '' : 's'} Added'
          : null,
    );

/// Token deleted — shows an UNDO chip for the hold duration.
Future<void> showTokenDeletedConfirmation(
  BuildContext context, {
  required Future<void> Function() perform,
  required String title,
  String? subtitle,
  String? code,
  required Future<void> Function() onUndo,
}) =>
    showTokenActionConfirmation(
      context,
      title: title,
      busyLabel: 'Deleting…',
      subtitle: subtitle,
      code: code,
      footnote: 'deleted from this phone and Drive',
      hold: const Duration(milliseconds: 4000),
      onUndo: onUndo,
      perform: perform,
    );

enum _Phase { busy, undo, done }

class _TokenConfirmView extends StatefulWidget {
  final String title;
  final String busyLabel;
  final String? subtitle;
  final String? code;
  final String? footnote;
  final Duration hold;
  final Future<void> Function()? onUndo;
  final Future<void> Function() perform;
  final ValueNotifier<int>? progress;
  final int? progressTotal;
  final String Function(int realCount)? doneTitleFor;

  const _TokenConfirmView({
    required this.title,
    required this.busyLabel,
    required this.subtitle,
    required this.code,
    required this.footnote,
    required this.hold,
    required this.onUndo,
    required this.perform,
    this.progress,
    this.progressTotal,
    this.doneTitleFor,
  });

  @override
  State<_TokenConfirmView> createState() => _TokenConfirmViewState();
}

class _TokenConfirmViewState extends State<_TokenConfirmView>
    with SingleTickerProviderStateMixin {
  // Lottie clock: composition frames 0-24 loop ("loop" marker), 24-54
  // completes ("complete" marker). t is exposed as 0..1 of the composition.
  late final _LottieClock knot;
  static const double _busyEnd = 24 / 54; // composition fraction
  _Phase _phase = _Phase.busy;

  @override
  void initState() {
    super.initState();
    knot = _LottieClock(vsync: this, busyEnd: _busyEnd, busyPeriodMs: 800);
    // Live counter: every insert bumps the notifier → busy line ticks.
    widget.progress?.addListener(_onProgressTick);
    _run();
  }

  void _onProgressTick() {
    if (mounted) setState(() {});
  }

  String get _busyText {
    final p = widget.progress;
    if (p != null && widget.progressTotal != null) {
      return '${widget.busyLabel} · ${p.value} of ${widget.progressTotal}';
    }
    return widget.busyLabel;
  }

  String get _doneText =>
      widget.doneTitleFor?.call(widget.progress?.value ?? 0) ?? widget.title;

  Future<void> _run() async {
    try {
      final minMotion = Future<void>.delayed(const Duration(milliseconds: 650));
      await Future.wait<void>([widget.perform(), minMotion]);
      if (!mounted) return;
      _beginDone();
    } catch (e) {
      // Close instantly and hand the real error back to the caller.
      if (mounted) Navigator.of(context).pop(e);
    }
  }

  Future<void> _beginDone() async {
    setState(() => _phase = _Phase.done);
    await knot.complete();
    await Future<void>.delayed(widget.hold);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _undo() async {
    if (widget.onUndo == null || _phase != _Phase.done) return;
    try {
      setState(() => _phase = _Phase.undo);
      final minMotion = Future<void>.delayed(const Duration(milliseconds: 500));
      await Future.wait<void>([widget.onUndo!(), minMotion]);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) Navigator.of(context).pop(e);
    }
  }

  @override
  void dispose() {
    widget.progress?.removeListener(_onProgressTick);
    knot.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final showUndo = _phase == _Phase.done && widget.onUndo != null;
    final canDismiss = _phase == _Phase.done;
    return Center(
      child: GestureDetector(
        onTap: canDismiss ? () => Navigator.of(context).pop() : null,
        child: Container(
          width: 250,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 22),
          decoration: BoxDecoration(
            color: AppTheme.cardBg,
            borderRadius: BorderRadius.circular(22),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.28),
                blurRadius: 26,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 92,
                height: 92,
                child: Lottie.asset(
                    'assets/fueltoken_anim/anim/token_done.json',
                    controller: knot,
                    fit: BoxFit.contain,
                    filterQuality: FilterQuality.low,
                  ),
              ),
              const SizedBox(height: 14),
              Text(
                _phase == _Phase.done ? _doneText : _busyText,
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.3,
                  color: _phase == _Phase.done ? AppTheme.textDark : AppTheme.textMid,
                ),
              ),
              if (widget.subtitle != null) ...[
                const SizedBox(height: 4),
                Text(
                  widget.subtitle!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1,
                    color: AppTheme.redeemedBlue,
                  ),
                ),
              ],
              if (widget.code != null) ...[
                const SizedBox(height: 2),
                Text(
                  '#${widget.code}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: AppTheme.textLight),
                ),
              ],
              if (showUndo) ...[
                const SizedBox(height: 12),
                _UndoChip(onTap: _undo),
              ],
              if (widget.footnote != null && canDismiss) ...[
                const SizedBox(height: 8),
                Text(widget.footnote!,
                    style: TextStyle(
                        fontSize: 10.5,
                        color: Colors.grey.shade500,
                        fontStyle: FontStyle.italic)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _UndoChip extends StatelessWidget {
  final VoidCallback onTap;
  const _UndoChip({required this.onTap});

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 7),
            decoration: BoxDecoration(
              color: AppTheme.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Text(
              'UNDO',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.2,
                color: AppTheme.primary,
              ),
            ),
          ),
        ),
      );
}
// ── Lottie clock: maps the confirmation art to two phases ──────────────────
// Composition of 54 frames @30fps: frames 0-24 = in-progress loop, frames
// 24-54 = completion (green disc + check draw + ripple). We drive t (0..1 of
// the whole composition) manually so only the loop part repeats, then the
// completion plays once.
class _LottieClock extends Animation<double> {
  _LottieClock({
    required TickerProvider vsync,
    required this.busyEnd,
    required this.busyPeriodMs,
  }) {
    _ticker = vsync.createTicker(_onTick);
    _ticker!.start();
  }

  Ticker? _ticker;
  final double busyEnd; // composition fraction where the loop part ends
  final int busyPeriodMs; // loop length in ms
  final Duration _finishSpan = const Duration(milliseconds: 1000);
  final List<VoidCallback> _listeners = <VoidCallback>[];
  final List<AnimationStatusListener> _statusListeners =
      <AnimationStatusListener>[];
  double _t = 0;
  bool _finishing = false;
  int? _finishStartUs;

  @override
  AnimationStatus get status => AnimationStatus.forward;

  @override
  double get value => _t;

  /// Plays the completion segment once, holds on the last frame.
  Future<void> complete() {
    if (_finishing) return Future<void>.value();
    _ticker!.stop();
    _finishing = true;
    _onStatus(AnimationStatus.forward);
    _ticker!.start();
    return Future<void>.delayed(_finishSpan);
  }

  void dispose() => _ticker!.dispose();

  void _onTick(Duration elapsed) {
    if (_finishing) {
      if (_finishStartUs == null) {
        _finishStartUs = elapsed.inMicroseconds;
        return;
      }
      final p = ((elapsed.inMicroseconds - _finishStartUs!) /
              _finishSpan.inMicroseconds)
          .clamp(0.0, 1.0);
      _t = busyEnd + (1 - busyEnd) * p;
    } else {
      final cycle = (elapsed.inMicroseconds % (busyPeriodMs * 1000)) /
          (busyPeriodMs * 1000);
      _t = cycle * busyEnd;
    }
    for (final l in List<VoidCallback>.of(_listeners)) {
      l();
    }
    if (_finishing && _t >= 1.0 && _ticker!.isActive) {
      _ticker!.stop();
      for (final l in List<AnimationStatusListener>.of(_statusListeners)) {
        l(AnimationStatus.completed);
      }
    }
  }

  @override
  void addListener(VoidCallback listener) => _listeners.add(listener);

  @override
  void removeListener(VoidCallback listener) => _listeners.remove(listener);

  @override
  void addStatusListener(AnimationStatusListener listener) =>
      _statusListeners.add(listener);

  @override
  void removeStatusListener(AnimationStatusListener listener) =>
      _statusListeners.remove(listener);

  void _onStatus(AnimationStatus s) {
    for (final l in List<AnimationStatusListener>.of(_statusListeners)) {
      l(s);
    }
  }

  @override
  String toString() => '_LottieClock(t=$_t)';
}
