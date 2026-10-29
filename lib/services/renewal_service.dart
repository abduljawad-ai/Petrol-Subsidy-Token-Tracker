import '../models/token_record.dart';

/// Weekly renewal logic. A vehicle becomes eligible for a NEW 9771 token the
/// moment its most recent token's expiry instant passes — that token may be
/// used or unused, it doesn't matter: the expiry timestamp is the gate.
///
/// The SMS states an exact time ("... 16:47 25-Oct تک قابلِ استعمال ہے"), so
/// the expiry is treated as that instant — not the end of the calendar day.
/// The reminder scheduler uses the same rule, so the notification and the
/// in-app Renew list can never disagree.
class RenewalService {
  RenewalService._();

  /// Vehicle plates are typed inconsistently ("LEA-1234", "lea 1234").
  /// One canonical key so the same vehicle is never treated as two.
  static String normalizeVehicle(String v) =>
      v.trim().toUpperCase().replaceAll(RegExp(r'[\s-]+'), '');

  static bool _isNewer(TokenRecord candidate, TokenRecord current) {
    final candExpiry = candidate.expiryDate ?? candidate.dateReceived;
    final currExpiry = current.expiryDate ?? current.dateReceived;
    if (candExpiry.isAfter(currExpiry)) return true;
    if (currExpiry.isAfter(candExpiry)) return false;

    if (candidate.dateReceived.isAfter(current.dateReceived)) return true;
    if (current.dateReceived.isAfter(candidate.dateReceived)) return false;

    return candidate.dateImported.isAfter(current.dateImported);
  }

  /// One entry per vehicle: the token to judge that vehicle by, i.e. the one
  /// with the latest expiry/issuance date. Shared by the renew list and the
  /// reminder scheduler so they can never disagree about who is due.
  static Map<String, TokenRecord> latestPerVehicle(List<TokenRecord> tokens) {
    final perVehicle = <String, TokenRecord>{};
    for (final t in tokens) {
      final key = normalizeVehicle(t.vehicleNumber);
      if (key.isEmpty) continue;
      final prev = perVehicle[key];
      if (prev == null || _isNewer(t, prev)) {
        perVehicle[key] = t;
      }
    }
    return perVehicle;
  }

  /// One entry per vehicle: the vehicle's most recent token, ONLY when that
  /// token's expiry instant has passed. Sorted by oldest expiry first
  /// (the vehicles waiting longest come out on top).
  static List<TokenRecord> renewables(List<TokenRecord> tokens,
      {DateTime? now}) {
    final at = now ?? DateTime.now();
    final out = <TokenRecord>[];
    for (final latest in latestPerVehicle(tokens).values) {
      final e = latest.expiryDate;
      if (e == null) continue;
      if (!e.isAfter(at)) out.add(latest);
    }
    out.sort((a, b) => a.expiryDate!.compareTo(b.expiryDate!));
    return out;
  }

  /// Is this specific vehicle allowed to receive a fresh token right now?
  /// A vehicle without any recorded tokens is naturally allowed.
  static bool canRequestNew(List<TokenRecord> tokens, String vehicleNumber,
      {DateTime? now}) {
    final at = now ?? DateTime.now();
    final latest = latestPerVehicle(tokens)[normalizeVehicle(vehicleNumber)];
    if (latest == null) return true;
    final e = latest.expiryDate ?? latest.dateReceived;
    return !e.isAfter(at);
  }
}
