import 'dart:async';

import 'package:flutter/material.dart';
import '../db/database_helper.dart';
import '../models/token_record.dart';
import '../services/drive_sync_service.dart';
import '../theme/app_graphics.dart';
import '../theme/app_theme.dart';
import '../widgets/active_token_card.dart';
import '../widgets/add_token_sheet.dart';
import '../widgets/ft_components.dart';
import '../widgets/token_used_overlay.dart';

import 'settings_screen.dart';
import 'token_detail_screen.dart';
import 'history_screen.dart';

/// App shell (v2): three tabs — Tokens · History · Settings.
/// "Used" tokens now live inside History (filter chip), so there is one
/// place for the past and one place for the present.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _db = DatabaseHelper();
  final _pageController = PageController(initialPage: 0);
  final DriveSyncService _sync = DriveSyncService.instance;

  List<TokenRecord> _activeThisWeek = [];
  List<TokenRecord> _otherActive = [];
  bool _loading = true;
  bool _syncPromptRunning = false;
  int _navIndex = 0;
  int _historyRevision = 0; // bumped to force HistoryScreen reload
  int _loadGeneration = 0; // stale async loads must not overwrite newer ones
  int _loadedWeek = _weekOfYear(DateTime.now());
  Timer? _expiryTicker;

  @override
  void initState() {
    super.initState();
    _load();
    // Live refresh: fires for THIS device's writes (add/use/delete) AND for
    // rows silently merged down from Drive a few seconds after open — so the
    // restored/updated list appears by itself, no manual refresh needed.
    DatabaseHelper.addChangeListener(_onDbWrite);
    // A token can expire while the app sits open. Without a tick the card
    // keeps saying ACTIVE and stays tappable until the next rebuild.
    _expiryTicker = Timer.periodic(const Duration(minutes: 1), (_) {
      if (!mounted || _navIndex != 0) return;
      final week = _weekOfYear(DateTime.now());
      final expired =
          _activeThisWeek.any((t) => t.isExpired) ||
          _otherActive.any((t) => t.isExpired);
      if (expired || week != _loadedWeek) _load(silent: true);
    });
    // Give the first frame a beat, then start sync + first-run prompts.
    Future.delayed(const Duration(milliseconds: 1600), _maybeSyncPrompt);
  }

  void _onDbWrite(DatabaseHelper _) {
    if (_navIndex == 0) _load(silent: true);
  }

  @override
  void dispose() {
    DatabaseHelper.removeChangeListener(_onDbWrite);
    _expiryTicker?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  /// [silent] keeps the current list on screen while refreshing — a DB write
  /// from sync or a background merge must never flash the spinner.
  Future<void> _load({bool silent = false}) async {
    if (!mounted) return;
    final generation = ++_loadGeneration;
    if (!silent) setState(() => _loading = true);
    try {
      // Expired tokens never appear on the main page: expiry is checked at
      // load time (status stays 'active' in DB but the pump won't accept
      // them). They remain accessible via History (red EXPIRED chip).
      final thisWeek =
          (await _db.getThisWeekActive()).where((t) => !t.isExpired).toList();
      final allActive =
          (await _db.getActiveTokens()).where((t) => !t.isExpired).toList();
      final thisWeekIds = thisWeek.map((t) => t.id).toSet();
      final other =
          allActive.where((t) => !thisWeekIds.contains(t.id)).toList();
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _activeThisWeek = thisWeek;
        _otherActive = other;
        _loading = false;
        _loadedWeek = _weekOfYear(DateTime.now());
      });
    } catch (err) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() => _loading = false);
      _snack('Could not load tokens: $err', AppTheme.danger);
    }
  }

  /// Mirrors DatabaseHelper's ISO-ish week numbering for the rollover tick.
  static int _weekOfYear(DateTime date) =>
      (date.difference(DateTime(date.year, 1, 1)).inDays / 7).floor() + 1;

  // ── ONE-TIME USE ───────────────────────────────────────────────────────────
  Future<void> _promptUseToken(TokenRecord token) async {
    if (token.status == TokenStatus.redeemed) {
      _snack('This token has already been used and cannot be reused.',
          AppTheme.pendingOrange);
      return;
    }
    if (token.isExpired) {
      _snack('This token has expired and cannot be used at the pump.',
          AppTheme.danger);
      return;
    }

    final confirmed = await showFtUseTokenDialog(context, token);
    if (!mounted || !confirmed) return;

    try {
      // Center-screen staged animation covers the DB write.
      await showTokenUsedConfirmation(
        context,
        vehicleNumber: token.vehicleNumber.toUpperCase(),
        tokenCode: token.tokenCode,
        perform: () => _db.markRedeemed(token.id),
      );
      await _load();
    } catch (err) {
      // NEVER fail silently: real DB error stays on-screen.
      _snack('Could not mark used: $err', AppTheme.danger);
    }
  }

  void _snack(String message, Color color, {SnackBarAction? action}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: color,
      duration: const Duration(seconds: 3),
      action: action,
    ));
  }

  // ── BUILD ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _buildAppBar(),
      body: Stack(
        alignment: Alignment.center,
        children: [
          PageView(
        controller: _pageController,
        onPageChanged: (i) {
          setState(() => _navIndex = i);
          if (i == 0) _load();
          if (i == 1) setState(() => _historyRevision++);
          // Page 2 (Settings) refreshes itself via DB write listeners.
        },
        children: [
          _buildTokensPage(),
          HistoryScreen(key: ValueKey('history-$_historyRevision')),
          const SyncSettingsBody(),
        ],
          ),
          if (_pulseVisible)
            IgnorePointer(
              child: AppIcons.lottie(AppIcons.animContentPulse,
                  size: 150, repeat: false),
            ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _navIndex,
        onDestinationSelected: (i) {
          _pageController.animateToPage(
            i,
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOut,
          );
        },
        destinations: [
          NavigationDestination(
            icon: _navIcon(AppIcons.navTokens, false),
            selectedIcon: _navIcon(AppIcons.navTokens, true),
            label: 'Tokens',
          ),
          NavigationDestination(
            icon: _navIcon(AppIcons.navHistory, false),
            selectedIcon: _navIcon(AppIcons.navHistory, true),
            label: 'History',
          ),
          NavigationDestination(
            icon: _navIcon(AppIcons.navSettings, false),
            selectedIcon: _navIcon(AppIcons.navSettings, true),
            label: 'Settings',
          ),
        ],
      ),
      floatingActionButton: _navIndex == 0
          ? FloatingActionButton.extended(
              onPressed: () => _maybeArrival(showAddTokenSheet(context)),
              icon: AppIcons.svg(AppIcons.add, size: 22, color: AppTheme.ink),
              label: const Text('Add Token',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
            )
          : null,
    );
  }

  AppBar _buildAppBar() {
    if (_navIndex == 0) {
      return AppBar(
        title: Row(
          children: [
            AppIcons.identity(AppIcons.logoMark, size: 28),
            const SizedBox(width: 10),
            const Text('FuelToken'),
          ],
        ),
      );
    }
    return AppBar(title: Text(_navIndex == 1 ? 'History' : 'Settings'));
  }

  /// Bottom-nav glyph tinted by selection state (line-set tint contract).
  Widget _navIcon(String asset, bool selected) => AppIcons.svg(asset,
      size: 22, color: selected ? AppTheme.primary : AppTheme.textMid);

  // ── TOKENS PAGE ────────────────────────────────────────────────────────────

  Widget _buildTokensPage() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final all = [..._activeThisWeek, ..._otherActive];
    return RefreshIndicator(
      onRefresh: _load,
      child: CustomScrollView(
        slivers: [
          if (all.isNotEmpty)
            SliverToBoxAdapter(child: _SummaryBanner(tokens: all)),

          if (all.isEmpty)
            const SliverToBoxAdapter(child: _EmptyWeekState()),

          if (_activeThisWeek.isNotEmpty) ...[
            if (_otherActive.isNotEmpty)
              SliverToBoxAdapter(
                child: FtSectionTitle('Ready to use at pump',
                    count: _activeThisWeek.length),
              )
            else
              const SliverToBoxAdapter(child: SizedBox(height: 4)),
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (ctx, i) => ActiveTokenCard(
                  token: _activeThisWeek[i],
                  onUseToken: () => _promptUseToken(_activeThisWeek[i]),
                  onTap: () => _openDetail(_activeThisWeek[i]),
                ),
                childCount: _activeThisWeek.length,
              ),
            ),
          ],

          if (_otherActive.isNotEmpty) ...[
            SliverToBoxAdapter(
              child: FtSectionTitle('Other available tokens',
                  count: _otherActive.length),
            ),
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (ctx, i) => ActiveTokenCard(
                  token: _otherActive[i],
                  onUseToken: () => _promptUseToken(_otherActive[i]),
                  onTap: () => _openDetail(_otherActive[i]),
                ),
                childCount: _otherActive.length,
              ),
            ),
          ],

          const SliverToBoxAdapter(child: SizedBox(height: 110)),
        ],
      ),
    );
  }

  // ── FIRST-RUN / RESTORE PROMPTS (once, never nagging) ──────────────────────
  Future<void> _maybeSyncPrompt() async {
    if (!mounted || _syncPromptRunning) return;
    _syncPromptRunning = true;
    await _sync.init(); // idempotent: also fires startup auto-sync if signed in

    final signedIn = _sync.state.value.signedIn;
    if (signedIn) {
      // Fresh app with a cloud backup → offer the restore.
      final count = await _db.tokenCount();
      if (count == 0 && await _db.getMeta('restore_prompt_done') != '1') {
        final backup = await _sync.peekCloudBackup();
        if (backup != null && backup.$1 > 0 && mounted) {
          final when = SyncText.lastSyncedLabel(backup.$2);
          final restore = await showFtConfirm(
            context,
            title: 'Backup found',
            message:
                '${backup.$1} token${backup.$1 == 1 ? '' : 's'} backed up in '
                'your Drive ($when). Load them into this phone?',
            confirmLabel: 'Load them',
            cancelLabel: 'Not now',
          );
          await _db.setMeta('restore_prompt_done', '1');
          if (restore && mounted) {
            await _sync.syncNow('restore');
            await _load();
          }
        } else {
          await _db.setMeta('restore_prompt_done', '1');
        }
      }
    } else if (!_sync.state.value.setupNeeded &&
        await _db.getMeta('sync_intro_done') != '1') {
      if (!mounted) return;
      final yes = await showFtConfirm(
        context,
        title: 'Back up automatically?',
        message: 'One Google tap keeps every token safe and brings them back '
            'even if you delete and reinstall this app.\n\n'
            'No password, no typing. You can skip it; the app works the same either way.',
        confirmLabel: 'Yes, with Google',
        cancelLabel: 'Not now',
      );
      await _db.setMeta('sync_intro_done', '1');
      if (yes && mounted) {
        // Called straight from the button tap → Android treats this as the
        // required user gesture for the account chooser / Drive consent.
        final acc = await _sync.signInFromUserGesture();
        if (acc != null && mounted) await _load();
      } else {
        // Respect "Not now": no account sheet, no silent sign-in, no Drive
        // traffic, until the user turns backup on themselves from the
        // Settings tab. The app works identically either way.
        await _db.setMeta('sync_declined', '1');
      }
    }
  }

  // ── NAVIGATION HELPERS ─────────────────────────────────────────────────────

  Future<void> _maybeArrival(Future<void> future) async {
    final before = _activeThisWeek.length + _otherActive.length;
    await future;
    await _load();
    final after = _activeThisWeek.length + _otherActive.length;
    if (after > before) _fireArrivalPulse();
  }

  /// Plays the delivered "token landed" burst once when fresh tokens appear.
  void _fireArrivalPulse() {
    if (!mounted) return;
    setState(() => _pulseVisible = true);
    Future<void>.delayed(const Duration(milliseconds: 800), () {
      if (mounted) setState(() => _pulseVisible = false);
    });
  }

  bool _pulseVisible = false;

  void _openDetail(TokenRecord token) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => TokenDetailScreen(token: token)),
    );
    _load();
  }

}

// ─── Summary banner ──────────────────────────────────────────────────────────

class _SummaryBanner extends StatelessWidget {
  final List<TokenRecord> tokens;
  const _SummaryBanner({required this.tokens});

  @override
  Widget build(BuildContext context) {
    TokenRecord? next;
    for (final t in tokens) {
      if (t.expiryDate == null) continue;
      if (next == null || t.expiryDate!.isBefore(next.expiryDate!)) next = t;
    }
    final total = tokens.fold<double>(0, (a, t) => a + (t.subsidyAmount ?? 0));

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: AppTheme.primary,
        borderRadius: BorderRadius.circular(AppTheme.rMd),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2.5),
            decoration: BoxDecoration(
              color: AppTheme.accent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '${tokens.length}',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w900,
                color: AppTheme.ink,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              tokens.length == 1
                  ? 'Token ready at pump'
                  : '${tokens.length} tokens ready at pump',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13.5,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          if (total > 0 || next != null)
            Text(
              [
                if (total > 0) 'Rs. ${total.toStringAsFixed(0)}',
                if (next != null) ftDeadlineLabel(next),
              ].join(' · '),
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.85),
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
              ),
            ),
        ],
      ),
    );
  }
}

// ─── Quick-add strip: three one-tap tiles ────────────────────────────────────

// ─── Empty state ─────────────────────────────────────────────────────────────

class _EmptyWeekState extends StatelessWidget {
  const _EmptyWeekState();

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 0),
        child: Column(
          children: [
            AppIcons.illustration('empty_tokens', width: 190),
            const SizedBox(height: 14),
            const Text(
              'No tokens ready this week',
              style: TextStyle(
                  fontSize: 19, fontWeight: FontWeight.w900, color: AppTheme.ink),
            ),
            const SizedBox(height: 8),
            const Text(
              'Tap Scan SMS and take a photo of your 9771 message.\nThe app reads it for you.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppTheme.textMid, height: 1.5, fontSize: 14),
            ),
          ],
        ),
      );
}
