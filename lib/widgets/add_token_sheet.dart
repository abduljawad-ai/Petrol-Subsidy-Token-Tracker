import 'package:flutter/material.dart';

import '../screens/add_token_screen.dart';
import '../screens/ocr_scan_screen.dart';
import '../screens/paste_sms_screen.dart';
import '../services/ocr_service.dart';
import '../theme/app_graphics.dart';
import '../theme/app_theme.dart';

/// The one Add Token entry point: camera / photos / paste / type in.
/// Nothing starts on its own — the user picks, then the flow begins.
/// Used by the Home FAB and the History renew rows.
Future<void> showAddTokenSheet(BuildContext context) async {
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppTheme.cardBg,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Add Token',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w900,
                    color: AppTheme.textMid)),
            const SizedBox(height: 10),
            GridView.count(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: 2,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 2.4,
              children: [
                _SheetTile(
                  icon: AppIcons.camera,
                  label: 'Camera',
                  onTap: () {
                    Navigator.pop(ctx);
                    _acquireAndOpen(context, OcrStart.camera);
                  },
                ),
                _SheetTile(
                  icon: AppIcons.gallery,
                  label: 'Photos',
                  onTap: () {
                    Navigator.pop(ctx);
                    _acquireAndOpen(context, OcrStart.gallery);
                  },
                ),
                _SheetTile(
                  icon: AppIcons.paste,
                  label: 'Paste SMS',
                  onTap: () {
                    Navigator.pop(ctx);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const PasteSmsScreen()),
                    );
                  },
                ),
                _SheetTile(
                  icon: AppIcons.editToken,
                  label: 'Type in',
                  onTap: () {
                    Navigator.pop(ctx);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const AddTokenScreen()),
                    );
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

/// Sheet pathway: acquire FIRST (camera / photos → auto-crop), then open
/// the scan view with the photos already in. Cancel anywhere → back to
/// where the user was, no intermediate page ever.
Future<void> _acquireAndOpen(BuildContext outer, OcrStart how) async {
  final root = Navigator.of(outer);
  final hasKey = await OcrService.hasKey();
  if (!outer.mounted) return;
  if (!hasKey) {
    // No OCR key yet → the scan screen explains (it has the shortcut).
    await root.push(MaterialPageRoute(builder: (_) => const OcrScanScreen()));
    return;
  }
  final photos = await acquireTokenPhotos(outer, how);
  if (photos == null) return; // cancelled camera/photos or every crop
  await root.push(MaterialPageRoute(
      builder: (_) => OcrScanScreen(seedPhotos: photos)));
}

class _SheetTile extends StatelessWidget {
  final String icon;
  final String label;
  final VoidCallback onTap;
  const _SheetTile({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) => Material(
        color: AppTheme.tint,
        borderRadius: BorderRadius.circular(AppTheme.rMd),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppTheme.rMd),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppTheme.rMd),
              border: Border.all(
                  color: AppTheme.primary.withValues(alpha: 0.25), width: 1.2),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AppIcons.svg(icon, size: 21, color: AppTheme.primary),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          color: AppTheme.ink)),
                ),
              ],
            ),
          ),
        ),
      );
}
