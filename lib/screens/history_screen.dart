import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../db/database_helper.dart';
import '../models/token_record.dart';
import '../theme/app_graphics.dart';
import '../theme/app_theme.dart';
import '../widgets/ft_components.dart';
import '../services/renewal_service.dart';
import '../widgets/add_token_sheet.dart';
import '../widgets/token_list_tile.dart';
import '../widgets/token_used_overlay.dart';
import 'token_detail_screen.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final _db = DatabaseHelper();
  List<TokenRecord> _tokens = [];
  List<TokenRecord> _filtered = [];
  String _query = '';
  String _statusFilter = 'All';
  bool _loading = true;
  final Set<String> _selectedIds = {};

  bool get _selecting => _selectedIds.isNotEmpty;

  // v2: the old "Used" tab was merged into History, so REDEEMED is a chip.
  final _statuses = ['All', 'RENEW', 'ACTIVE', 'REDEEMED', 'EXPIRED'];
  static const _statusNames = {
    'All': 'All',
    'RENEW': 'Renew',
    'ACTIVE': 'Active',
    'REDEEMED': 'Used',
    'EXPIRED': 'Expired',
  };

  int _countFor(String s) => s == 'All'
      ? _tokens.length
      : s == 'RENEW'
          ? RenewalService.renewables(_tokens).length
          : _tokens.where((t) => t.statusLabel == s).length;

  @override
  void initState() {
    super.initState();
    _load();
  }

  // ── BULK SELECTION ──────────────────────────────────────────────────────────
  void _toggleSelect(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
    });
  }

  bool get _allVisibleSelected =>
      _filtered.isNotEmpty && _filtered.every((t) => _selectedIds.contains(t.id));

  void _toggleSelectAll() {
    setState(() {
      if (_allVisibleSelected) {
        _selectedIds.clear();
      } else {
        _selectedIds
          ..clear()
          ..addAll(_filtered.map((t) => t.id));
      }
    });
  }

  Future<void> _exitSelection() async {
    setState(() => _selectedIds.clear());
  }

  Future<void> _deleteSelected() async {
    final ids = _selectedIds.toList();
    if (ids.isEmpty) return;
    final n = ids.length;

    final confirmed = await showFtConfirm(
      context,
      title: 'Delete $n token${n == 1 ? '' : 's'}?',
      message:
          'They will be removed from this phone.\nYou get one UNDO right after.',
      confirmLabel: 'Delete',
      cancelLabel: 'Keep',
      danger: true,
    );
    if (!confirmed) return;
    if (!mounted) return;

    // Snapshot for UNDO before removing.
    final snapshot = _tokens.where((t) => ids.contains(t.id)).toList();

    setState(() => _selectedIds.clear());
    try {
      await showTokenDeletedConfirmation(
        context,
        title: '$n Token${n == 1 ? '' : 's'} Deleted',
        subtitle: n == 1 ? snapshot.first.vehicleNumber.toUpperCase() : null,
        code: n == 1 ? snapshot.first.tokenCode : null,
        perform: () => _db.deleteTokens(ids),
        onUndo: () => _restore(snapshot),
      );
    } catch (err) {
      // NEVER fail silently: show the real database error.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Delete failed: $err'),
          backgroundColor: AppTheme.danger,
        ));
      }
      return;
    }
    await _load();
  }

  Future<void> _restore(List<TokenRecord> records) async {
    await _db.restoreTokens(records.map((r) => r.id).toList());
    await _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _loading = true);
    final all = await _db.getAllTokens();
    if (mounted) {
      setState(() {
        _tokens = all;
        _loading = false;
        _applyFilter();
      });
    }
  }

  void _applyFilter() {
    var result = _tokens;
    if (_statusFilter == 'RENEW') {
      result = RenewalService.renewables(result);
    } else if (_statusFilter != 'All') {
      result = result.where((t) => t.statusLabel == _statusFilter).toList();
    }
    if (_query.isNotEmpty) {
      final q = _query.toLowerCase();
      result = result.where((t) =>
          t.tokenCode.toLowerCase().contains(q) ||
          t.vehicleNumber.toLowerCase().contains(q) ||
          (t.personName?.toLowerCase().contains(q) ?? false) ||
          (t.mobileNumber?.contains(q) ?? false)).toList();
    }
    _filtered = result;
  }

  @override
  Widget build(BuildContext context) {
    // Bare content — the outer shell provides the header.
    return Column(
      children: [
        // Selection bar replaces the search field while selecting.
        if (_selecting) _selectionBar() else _searchField(),
        _filterRow(),
        if (!_loading && _filtered.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 2, 20, 2),
            child: Row(
              children: [
                Text(
                  '${_filtered.length} token${_filtered.length == 1 ? '' : 's'}',
                  style: const TextStyle(
                      color: AppTheme.textMid,
                      fontSize: 13,
                      fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                if (!_selecting)
                  const Text('Long-press to select',
                      style: TextStyle(color: AppTheme.textLight, fontSize: 12)),
              ],
            ),
          ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _filtered.isEmpty
                  ? _buildEmpty()
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView.builder(
                        padding: const EdgeInsets.only(top: 4, bottom: 90),
                        itemCount: _filtered.length,
                        itemBuilder: (ctx, i) {
                          final t = _filtered[i];
                          final isSel = _selectedIds.contains(t.id);
                          if (_statusFilter == 'RENEW') {
                            return _RenewTile(
                              token: t,
                              rank: i + 1,
                              onRequest: () => _requestNewToken(t),
                              onTap: () async {
                                await Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                      builder: (_) =>
                                          TokenDetailScreen(token: t)),
                                );
                                _load();
                              },
                            );
                          }
                          return TokenListTile(
                            token: t,
                            selected: _selecting ? isSel : null,
                            onLongPress: () => _toggleSelect(t.id),
                            onTap: () async {
                              if (_selecting) {
                                _toggleSelect(t.id);
                                return;
                              }
                              await Navigator.push(
                                context,
                                MaterialPageRoute(
                                    builder: (_) => TokenDetailScreen(token: t)),
                              );
                              _load();
                            },
                          );
                        },
                      ),
                    ),
        ),
      ],
    );
  }

  Widget _searchField() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: TextField(
          onChanged: (v) => setState(() {
            _query = v;
            _applyFilter();
          }),
          decoration: InputDecoration(
            hintText: 'Search token, vehicle or name',
            prefixIcon: Padding(
              padding: const EdgeInsets.all(14),
              child: AppIcons.svg(AppIcons.search,
                  size: 20, color: AppTheme.textMid),
            ),
            contentPadding: const EdgeInsets.symmetric(vertical: 14),
          ),
        ),
      );

  Widget _selectionBar() => Container(
        margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        padding: const EdgeInsets.fromLTRB(4, 4, 8, 4),
        decoration: BoxDecoration(
          color: AppTheme.tint,
          borderRadius: BorderRadius.circular(AppTheme.rMd),
          border: Border.all(color: AppTheme.activeGreen.withValues(alpha: 0.35)),
        ),
        child: Row(
          children: [
            IconButton(
              tooltip: 'Cancel selection',
              icon: AppIcons.svg(AppIcons.navClose,
                  size: 20, color: AppTheme.textMid),
              onPressed: _exitSelection,
            ),
            Text(
              '${_selectedIds.length} selected',
              style: const TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 15,
                  color: AppTheme.ink),
            ),
            const Spacer(),
            TextButton(
              onPressed: _toggleSelectAll,
              child: Text(_allVisibleSelected ? 'Clear' : 'Select all'),
            ),
            const SizedBox(width: 4),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.danger,
                minimumSize: const Size(64, 42),
                padding: const EdgeInsets.symmetric(horizontal: 14),
              ),
              onPressed: _deleteSelected,
              icon: AppIcons.svg(AppIcons.deleteToken,
                  size: 18, color: Colors.white),
              label: const Text('Delete'),
            ),
          ],
        ),
      );

  Widget _filterRow() => SizedBox(
        height: 56,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
          itemCount: _statuses.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (ctx, i) {
            final s = _statuses[i];
            final selected = _statusFilter == s;
            final color = s == 'All' ? AppTheme.primary : AppTheme.statusColor(s);
            return Material(
              color: selected ? color : AppTheme.cardBg,
              borderRadius: BorderRadius.circular(22),
              child: InkWell(
                borderRadius: BorderRadius.circular(22),
                onTap: () => setState(() {
                  _statusFilter = s;
                  _applyFilter();
                }),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(
                        color: selected ? color : AppTheme.line, width: 1.4),
                  ),
                  child: Text(
                    '${_statusNames[s]}  ${_countFor(s)}',
                    style: TextStyle(
                      color: selected ? Colors.white : AppTheme.ink,
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      );

  /// Renew action: copy the vehicle number for the request SMS, open the
  /// Add Token sheet for the reply, then refresh this list.
  Future<void> _requestNewToken(TokenRecord token) async {
    await Clipboard.setData(
        ClipboardData(text: token.vehicleNumber.toUpperCase()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      duration: Duration(seconds: 2),
      content: Text(
          'Vehicle number copied. Send your request SMS; when the reply arrives, use Add Token to save it.'),
    ));
    await showAddTokenSheet(context);
    if (mounted) _load();
  }

  Widget _buildEmpty() {
    final searching = _query.isNotEmpty;
    final usedView = _statusFilter == 'REDEEMED';
    final renewView = _statusFilter == 'RENEW';
    return FtEmptyState(
      art: AppIcons.illustration('empty_history', width: 180),
      title: searching
          ? 'No results'
          : renewView
              ? 'Nothing to renew'
              : usedView
                  ? 'Nothing used yet'
                  : 'No tokens here',
      message: searching
          ? 'Nothing matches "$_query". Try a shorter search.'
          : renewView
              ? 'A vehicle shows here when its latest token date has fully passed. A reminder message also arrives at that time.'
              : usedView
                  ? 'Tokens you confirm at the pump show up here with the exact time they were used.'
                  : 'Tokens you add will appear in this list.',
    );
  }
}

/// One vehicle waiting for a fresh 9771 token. Shown in the History
/// Renew filter. The button copies the vehicle number (it feeds the
/// request SMS) and opens the Add Token sheet for the reply.
class _RenewTile extends StatelessWidget {
  final TokenRecord token;
  final int rank;
  final VoidCallback onTap;
  final Future<void> Function() onRequest;
  const _RenewTile({required this.token, required this.rank,
      required this.onTap, required this.onRequest});

  @override
  Widget build(BuildContext context) {
    final e = token.expiryDate!;
    final expiredFor =
        DateTime.now().difference(DateTime(e.year, e.month, e.day)).inDays;
    final whenText = expiredFor <= 0
        ? 'expired today'
        : 'expired $expiredFor day${expiredFor == 1 ? '' : 's'} ago';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: Material(
        color: AppTheme.cardBg,
        borderRadius: BorderRadius.circular(AppTheme.rMd),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppTheme.rMd),
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppTheme.rMd),
              border: Border.all(color: AppTheme.accent, width: 1.2),
            ),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: AppTheme.accent.withValues(alpha: 0.18),
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: Text('$rank',
                      style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w900,
                          color: AppTheme.ink)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        token.vehicleNumber.toUpperCase(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.8,
                            color: AppTheme.textDark),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Token expired on ${_fmt(e)} — $whenText',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 12, color: AppTheme.textMid),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Material(
                  color: AppTheme.accent,
                  borderRadius: BorderRadius.circular(999),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(999),
                    onTap: onRequest,
                    child: const Padding(
                      padding:
                          EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                      child: Text('Request\nnew token',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: 11.5,
                              height: 1.15,
                              fontWeight: FontWeight.w900,
                              color: AppTheme.ink)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _fmt(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')} ${_month(d.month)} ${d.year}';

  static const _months = [
    '',
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec'
  ];
  static String _month(int m) => _months[m];
}
