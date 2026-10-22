import '../models/token_record.dart';

/// Weekly renewal logic. A vehicle becomes eligible for a NEW 9771 token
/// only when its most recent token's expiry date has fully passed — that
/// token may be used or unused, it doesn't matter: the date is the gate.
class RenewalService {
  RenewalService._();

  /// One entry per vehicle: the vehicle's most recent token, ONLY when
  /// that token's expiry day is over. Sorted by oldest expiry first
  /// (the vehicles waiting longest come out on top).
  static List<TokenRecord> renewables(List<TokenRecord> tokens,
      {DateTime? now}) {
    final at = now ?? DateTime.now();
    final perVehicle = <String, TokenRecord>{};
    for (final t in tokens) {
      final key = _norm(t.vehicleNumber);
      if (key.isEmpty) continue;
      final prev = perVehicle[key];
      // Remember: expiry day ends at 23:59 — until then the vehicle is busy.
      if (prev == null || _imported(t).isAfter(_imported(prev))) perVehicle[key] = t;
    }
    final out = <TokenRecord>[];
    for (final latest in perVehicle.values) {
      final e = latest.expiryDate;
      if (e == null) continue;
      final endOfDay = DateTime(e.year, e.month, e.day, 23, 59, 59);
      if (endOfDay.isBefore(at)) out.add(latest);
    }
    out.sort((a, b) => a.expiryDate!.compareTo(b.expiryDate!));
    return out;
  }

  /// Is this specific vehicle allowed to receive a fresh token right now?
  static bool canRequestNew(List<TokenRecord> tokens, String vehicleNumber,
      {DateTime? now}) {
    final at = now ?? DateTime.now();
    final key = _norm(vehicleNumber);
    TokenRecord? latest;
    for (final t in tokens) {
      if (_norm(t.vehicleNumber) != key) continue;
      if (latest == null || _imported(t).isAfter(_imported(latest))) latest = t;
    }
    final e = latest?.expiryDate;
    if (e == null) return false;
    return DateTime(e.year, e.month, e.day, 23, 59, 59).isBefore(at);
  }

  static String _norm(String v) =>
      v.trim().toUpperCase().replaceAll(RegExp(r'[\s-]+'), '');

  /// The token to judge a vehicle by = the one imported most recently.
  static DateTime _imported(TokenRecord t) =>
      t.dateImported;
}
