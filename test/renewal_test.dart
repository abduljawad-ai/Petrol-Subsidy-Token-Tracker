import 'package:flutter_test/flutter_test.dart';
import 'package:fueltoken_tracker/models/token_record.dart';
import 'package:fueltoken_tracker/services/renewal_service.dart';

TokenRecord token(String code,
    {required String vehicle, required DateTime imported, DateTime? expiry,
    bool redeemed = false}) {
  return TokenRecord(
    id: 'id-$code',
    tokenCode: code,
    vehicleNumber: vehicle,
    vehicleType: VehicleType.motorcycle,
    status: redeemed ? TokenStatus.redeemed : TokenStatus.active,
    dateReceived: imported,
    dateImported: imported,
    expiryDate: expiry,
    subsidyAmount: 500.0,
    fuelLitres: 20,
  );
}

void main() {
  test('Vehicle is NOT eligible while any token date is still ahead', () {
    final t = token('1111222233',
        vehicle: 'ABC-123',
        imported: DateTime.now().subtract(const Duration(days: 3)),
        expiry: DateTime.now().add(const Duration(days: 4)));
    expect(RenewalService.renewables([t], now: DateTime.now()), isEmpty);
    expect(RenewalService.canRequestNew([t], 'ABC-123', now: DateTime.now()), isFalse);
  });

  test('Used token still blocks renewal until its exact expiry instant', () {
    final expiry = DateTime(2026, 1, 20, 16, 47);
    final used = token('4444555566',
        vehicle: 'XYZ-9',
        imported: DateTime(2026, 1, 13),
        expiry: expiry,
        redeemed: true);
    // Even used, the vehicle waits for the token's own expiry time.
    expect(
        RenewalService.renewables([used],
                now: expiry.subtract(const Duration(minutes: 1)))
            .isEmpty,
        isTrue);
    expect(RenewalService.renewables([used], now: expiry).length, 1);
  });

  test('Expired (used or not) becomes renew-available after its expiry', () {
    final start = DateTime(2026, 1, 10, 9);
    final expiredU = token('A1B2C3D4E5',
        vehicle: 'ABC-123',
        imported: start,
        expiry: start.add(const Duration(days: 7)),
        redeemed: true);
    final expiredN = token('F6G7H8I9J0',
        vehicle: 'LMN-45',
        imported: start,
        expiry: DateTime(2026, 1, 15));
    // vs an active non-used vehicle for contrast
    final active = token('K1K2K3K4K5',
        vehicle: 'RS-1', imported: start, expiry: DateTime(2026, 5, 1));
    final after = DateTime(2026, 1, 19);
    final list = RenewalService.renewables([expiredU, expiredN, active],
        now: after);
    // One row per vehicle, oldest expiry first.
    expect(list.map((t) => t.vehicleNumber), ['LMN-45', 'ABC-123']);
    expect(RenewalService.canRequestNew([expiredU], 'ABC-123', now: after), isTrue);
    expect(RenewalService.canRequestNew([active], 'RS-1', now: after), isFalse);
  });

  test('Older expired token does not count when a newer token exists', () {
    final older =
        token('1111222233', vehicle: 'ABC-123',
            imported: DateTime(2026, 1, 1), expiry: DateTime(2026, 1, 8));
    final newer = token('9999888877', vehicle: 'ABC-123',
        imported: DateTime(2026, 1, 9), expiry: DateTime(2026, 3, 1));
    expect(RenewalService.renewables([older, newer],
        now: DateTime(2026, 1, 20)), isEmpty,
        reason: 'the current token is still valid — no renewal slot');
  });

  test('Same vehicle matches despite spacing/case variants', () {
    final a = token('1111222233', vehicle: 'abc-123',
        imported: DateTime(2026, 1, 1), expiry: DateTime(2026, 1, 2));
    final now = DateTime(2026, 1, 10);
    expect(RenewalService.renewables([a], now: now).length, 1);
    expect(RenewalService.canRequestNew([a], 'ABC 123', now: now), isTrue);
  });

  test('normalizeVehicle folds case, spaces and dashes', () {
    expect(RenewalService.normalizeVehicle('  lea-1234 '), 'LEA1234');
    expect(RenewalService.normalizeVehicle('lea 1234'), 'LEA1234');
    expect(RenewalService.normalizeVehicle('   '), isEmpty);
  });

  test('renewal unlocks at the exact expiry instant, not end of day', () {
    final expiry = DateTime(2026, 10, 25, 16, 47);
    final t = token('1111222233',
        vehicle: 'ABC-123',
        imported: DateTime(2026, 10, 18),
        expiry: expiry);

    expect(
        RenewalService.canRequestNew([t], 'ABC-123',
            now: expiry.subtract(const Duration(minutes: 1))),
        isFalse);
    expect(RenewalService.canRequestNew([t], 'ABC-123', now: expiry), isTrue);
    expect(RenewalService.renewables([t], now: expiry).length, 1);
    expect(
        RenewalService.renewables([t],
                now: expiry.subtract(const Duration(seconds: 1)))
            .length,
        0);
  });

  test('latestPerVehicle keeps one row per plate, newest import wins', () {
    final old = token('1111222233',
        vehicle: 'abc-123',
        imported: DateTime(2026, 1, 1),
        expiry: DateTime(2026, 1, 8));
    final newest = token('9999888877',
        vehicle: 'ABC 123',
        imported: DateTime(2026, 1, 9),
        expiry: DateTime(2026, 2, 1));
    final other = token('5555666677',
        vehicle: 'XYZ-9',
        imported: DateTime(2026, 1, 5),
        expiry: DateTime(2026, 1, 6));

    final latest = RenewalService.latestPerVehicle([old, newest, other]);
    expect(latest.length, 2);
    expect(latest['ABC123']?.id, 'id-9999888877');
    expect(latest['XYZ9']?.id, 'id-5555666677');
  });

  test('Newer expiry wins even if older expired token was imported later', () {
    final olderExpired = token('1111222233',
        vehicle: 'ABC-123',
        imported: DateTime(2026, 2, 1), // imported later
        expiry: DateTime(2026, 1, 8)); // expired early
    final activeValid = token('9999888877',
        vehicle: 'ABC-123',
        imported: DateTime(2026, 1, 9), // imported earlier
        expiry: DateTime(2026, 3, 1)); // valid until March

    final latest = RenewalService.latestPerVehicle([olderExpired, activeValid]);
    expect(latest['ABC123']?.id, 'id-9999888877');
    expect(RenewalService.canRequestNew([olderExpired, activeValid], 'ABC-123',
        now: DateTime(2026, 1, 20)), isFalse);
  });

  test('canRequestNew returns true for unknown vehicle with no tokens', () {
    expect(RenewalService.canRequestNew([], 'NEW-999'), isTrue);
  });
}
