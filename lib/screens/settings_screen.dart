import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../db/database_helper.dart';
import '../services/drive_sync_service.dart';
import '../services/ocr_service.dart';
import '../theme/app_graphics.dart';
import '../theme/app_theme.dart';
import '../widgets/ft_components.dart';

/// Settings tab body — embedded as the last page of the home shell.
/// Contains:
/// 1. Photo reading (AI Scanner) with Gemini API key guide and direct link
/// 2. Google Drive Backup & Sync status
/// 3. Developer info
class SyncSettingsBody extends StatefulWidget {
  const SyncSettingsBody({super.key});

  @override
  State<SyncSettingsBody> createState() => _SyncSettingsBodyState();
}

class _SyncSettingsBodyState extends State<SyncSettingsBody> {
  final DriveSyncService _sync = DriveSyncService.instance;
  final DatabaseHelper _db = DatabaseHelper();
  int _tokenCount = 0;

  /// Custom redesigned sign out confirmation dialog.
  Future<void> _confirmSignOut() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        elevation: 0,
        backgroundColor: AppTheme.cardBg,
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: Colors.red.shade50,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Center(
                      child: Icon(Icons.logout_rounded,
                          color: AppTheme.danger, size: 22),
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Sign out?',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                        color: AppTheme.ink,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              const Text(
                'Your tokens stay saved on this phone. Cloud backup will be paused until you sign in again.',
                style: TextStyle(
                  fontSize: 13.5,
                  color: AppTheme.textMid,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text(
                        'Stay signed in',
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.danger,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text(
                        'Sign out',
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    if (ok == true) {
      await _sync.signOut();
    }
  }

  @override
  void initState() {
    super.initState();
    _sync.init();
    DatabaseHelper.addWriteListener(_onDbWrite);
    _refreshCount();
  }

  @override
  void dispose() {
    DatabaseHelper.removeWriteListener(_onDbWrite);
    super.dispose();
  }

  void _onDbWrite(DatabaseHelper _) => _refreshCount();

  Future<void> _refreshCount() async {
    _tokenCount = await _db.tokenCount();
    if (mounted) setState(() {});
  }

  Future<void> _signIn() async {
    await _sync.signInFromUserGesture();
    await _refreshCount();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 36),
      children: [
        // ── Photo reading (AI Scanner) ─────────────────────────────────────
        const FtSectionTitle('Photo reading',
            padding: EdgeInsets.fromLTRB(20, 14, 20, 6)),
        const _OcrKeyCard(),

        // ── Backup & Sync ──────────────────────────────────────────────────
        const FtSectionTitle('Backup & Sync',
            padding: EdgeInsets.fromLTRB(20, 18, 20, 6)),
        ValueListenableBuilder<SyncState>(
          valueListenable: _sync.state,
          builder: (ctx, s, _) => FtSurface(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: AppTheme.tint,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Center(
                        child: AppIcons.svg(
                          s.signedIn ? AppIcons.cloudIdle : AppIcons.cloudBackUp,
                          color: AppTheme.primary,
                          size: 22,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        s.signedIn ? 'Backup is on' : 'Back up to Google Drive',
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 16,
                          color: AppTheme.ink,
                        ),
                      ),
                    ),
                    FtPill(
                      s.signedIn ? 'ON' : 'OFF',
                      color:
                          s.signedIn ? AppTheme.activeGreen : AppTheme.textLight,
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                const Text(
                  'Your tokens stay backed up in your private Google Drive folder and sync automatically.',
                  style: TextStyle(
                    fontSize: 13,
                    color: AppTheme.textMid,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 14),

                if (!s.signedIn)
                  FtPrimaryButton(
                    label: 'Continue with Google',
                    iconAsset: AppIcons.cloudBackUp,
                    busy: s.busy,
                    onPressed: _signIn,
                  ),

                if (s.signedIn) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppTheme.surface,
                      borderRadius: BorderRadius.circular(AppTheme.rMd),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                s.email ?? 'Google account',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 14,
                                  color: AppTheme.ink,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Row(
                                children: [
                                  if (s.busy)
                                    const SizedBox(
                                      width: 12,
                                      height: 12,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  else
                                    AppIcons.svg(
                                      s.error == null
                                          ? AppIcons.stateDone
                                          : AppIcons.stateFailed,
                                      size: 14,
                                      color: s.error == null
                                          ? AppTheme.activeGreen
                                          : AppTheme.danger,
                                    ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      s.error != null
                                          ? 'Sync problem'
                                          : 'Synced ${SyncText.lastSyncedLabel(s.lastSyncedAt)}'
                                              ' · $_tokenCount tokens',
                                      style: TextStyle(
                                        fontSize: 12.5,
                                        color: s.error == null
                                            ? AppTheme.textMid
                                            : AppTheme.danger,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: AppIcons.svg(
                            AppIcons.cloudBackUp,
                            size: 19,
                            color: AppTheme.primary,
                          ),
                          label: const Text('Sync now'),
                          onPressed:
                              s.busy ? null : () => _sync.syncNow('manual'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      TextButton.icon(
                        style: TextButton.styleFrom(
                          foregroundColor: AppTheme.danger,
                        ),
                        icon: const Icon(Icons.logout_rounded, size: 18),
                        label: const Text('Sign out'),
                        onPressed: s.busy ? null : _confirmSignOut,
                      ),
                    ],
                  ),
                ],

                if (s.error != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.red.shade50,
                      borderRadius: BorderRadius.circular(AppTheme.rSm),
                    ),
                    child: Text(
                      s.error!,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: Colors.red.shade800,
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),

        const SizedBox(height: 24),
        const _VersionFooter(),
      ],
    );
  }
}

/// Footer: the GitHub mark (opens the project's profile) next to the real
/// app version — read from the installed APK itself, so the number always
/// matches the actual build without any manual editing.
class _VersionFooter extends StatelessWidget {
  const _VersionFooter();

  static const String _githubUrl = 'https://github.com/abduljawad-ai';

  @override
  Widget build(BuildContext context) {
    return Center(
      child: InkWell(
        onTap: () => launchUrl(
          Uri.parse(_githubUrl),
          mode: LaunchMode.externalApplication,
        ),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // The GitHub mark — a visible, obvious link, not a hidden one.
              SvgPicture.asset(
                AppIcons.brandGithub,
                width: 16,
                height: 16,
                fit: BoxFit.contain,
              ),
              const SizedBox(width: 7),
              FutureBuilder<PackageInfo>(
                future: PackageInfo.fromPlatform(),
                builder: (context, snap) {
                  final v = snap.data?.version ?? '';
                  return Text(
                    'FuelToken Tracker · v$v',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textLight,
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── OCR key card with step-by-step guide & direct link ──────────────────────

class _OcrKeyCard extends StatefulWidget {
  const _OcrKeyCard();

  @override
  State<_OcrKeyCard> createState() => _OcrKeyCardState();
}

class _OcrKeyCardState extends State<_OcrKeyCard> {
  final DatabaseHelper _db = DatabaseHelper();
  final TextEditingController _ctrl = TextEditingController();
  final FocusNode _focus = FocusNode();
  String? _key;
  bool _showField = false;
  bool _obscure = true;
  bool _working = false;

  @override
  void initState() {
    super.initState();
    DatabaseHelper().getMeta(kOcrKeyMeta).then((v) {
      if (mounted) {
        setState(() => _key = (v == null || v.trim().isEmpty) ? null : v.trim());
      }
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  String get _masked {
    final k = _key ?? '';
    return k.length <= 12
        ? '••••••••'
        : '${k.substring(0, 6)} •••••••• ${k.substring(k.length - 4)}';
  }

  Future<void> _openApiKeyPage() async {
    final uri = Uri.parse('https://aistudio.google.com/app/apikey');
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text != null && text.isNotEmpty) {
      _ctrl.text = text;
      if (mounted) setState(() {});
    }
  }

  Future<void> _save() async {
    final k = _ctrl.text.trim();
    if (k.isEmpty || _working) return;
    setState(() => _working = true);
    await _db.setMeta(kOcrKeyMeta, k);
    if (!mounted) return;
    setState(() {
      _key = k;
      _ctrl.clear();
      _showField = false;
      _working = false;
    });
    FocusScope.of(context).unfocus();
  }

  Future<void> _remove() async {
    if (_working) return;
    setState(() => _working = true);
    await _db.setMeta(kOcrKeyMeta, '');
    if (!mounted) return;
    setState(() {
      _key = null;
      _showField = false;
      _working = false;
    });
  }

  Widget _buildStep(String num, String text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            color: AppTheme.primary,
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: Text(
            num,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w900,
              color: Colors.white,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              fontSize: 12.5,
              color: AppTheme.ink,
              height: 1.35,
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasKey = _key != null;
    return FtSurface(
      borderColor: hasKey ? AppTheme.line : AppTheme.accent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: hasKey
                      ? AppTheme.tint
                      : AppTheme.accent.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Center(
                  child: AppIcons.svg(
                    AppIcons.keyOcr,
                    color: hasKey ? AppTheme.primary : AppTheme.ink,
                    size: 22,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'Photo reading (Gemini)',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                    color: AppTheme.ink,
                  ),
                ),
              ),
              FtPill(
                hasKey ? 'READY' : 'SETUP',
                color: hasKey ? AppTheme.activeGreen : AppTheme.ink,
                filled: !hasKey,
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            hasKey
                ? 'Your Google Gemini key is active. Token photos are read automatically.'
                : 'Scans paper token receipts using Google Gemini AI. Free and fast.',
            style: const TextStyle(
              fontSize: 13,
              color: AppTheme.textMid,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 14),

          // ── Guide box when no key or editing ──────────────────────────────
          if (!hasKey || _showField) ...[
            Container(
              padding: const EdgeInsets.all(13),
              decoration: BoxDecoration(
                color: AppTheme.surface,
                borderRadius: BorderRadius.circular(AppTheme.rMd),
                border: Border.all(color: AppTheme.line),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'How to get a free API key:',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: AppTheme.ink,
                    ),
                  ),
                  const SizedBox(height: 9),
                  _buildStep('1', 'Tap the button below to open Google AI Studio.'),
                  const SizedBox(height: 6),
                  _buildStep('2', 'Sign in and click "Create API key".'),
                  const SizedBox(height: 6),
                  _buildStep('3', 'Copy the key and paste it in the field below.'),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.open_in_new_rounded, size: 16),
                      label: const Text('Get Free Gemini API Key ↗'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppTheme.primary,
                        side: const BorderSide(color: AppTheme.primary, width: 1.2),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      onPressed: _openApiKeyPage,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
          ],

          if (hasKey && !_showField) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              decoration: BoxDecoration(
                color: AppTheme.surface,
                borderRadius: BorderRadius.circular(AppTheme.rMd),
              ),
              child: Row(
                children: [
                  AppIcons.svg(AppIcons.lock, color: AppTheme.textMid, size: 18),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _masked,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5,
                        color: AppTheme.ink,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed:
                        _working ? null : () => setState(() => _showField = true),
                    child: const Text('Change key'),
                  ),
                ),
                const SizedBox(width: 10),
                TextButton(
                  onPressed: _working ? null : _remove,
                  style: TextButton.styleFrom(foregroundColor: AppTheme.danger),
                  child: const Text('Remove'),
                ),
              ],
            ),
          ] else ...[
            TextField(
              controller: _ctrl,
              focusNode: _focus,
              obscureText: _obscure,
              autofillHints: const [],
              enableSuggestions: false,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _save(),
              style: const TextStyle(fontSize: 14),
              decoration: InputDecoration(
                hintText: hasKey ? 'Paste the new key' : 'Paste your Gemini key',
                prefixIcon: Padding(
                  padding: const EdgeInsets.all(14),
                  child: AppIcons.svg(AppIcons.keyOcr,
                      size: 20, color: AppTheme.textMid),
                ),
                suffixIcon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Paste from clipboard',
                      icon: const Icon(Icons.content_paste_rounded,
                          size: 20, color: AppTheme.primary),
                      onPressed: _pasteFromClipboard,
                    ),
                    IconButton(
                      tooltip: _obscure ? 'Show key' : 'Hide key',
                      icon: AppIcons.svg(
                        _obscure ? AppIcons.eyeOff : AppIcons.eye,
                        size: 20,
                        color: AppTheme.textMid,
                      ),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FtPrimaryButton(
                    label: hasKey ? 'Save new key' : 'Save key',
                    iconAsset: AppIcons.saveToken,
                    busy: _working,
                    onPressed: _save,
                  ),
                ),
                if (hasKey) ...[
                  const SizedBox(width: 10),
                  TextButton(
                    onPressed: _working
                        ? null
                        : () => setState(() {
                              _showField = false;
                              _ctrl.clear();
                            }),
                    child: const Text('Cancel'),
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.surface,
      appBar: AppBar(title: const Text('Settings')),
      body: const SyncSettingsBody(),
    );
  }
}
