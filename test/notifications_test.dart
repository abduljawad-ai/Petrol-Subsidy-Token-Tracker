import 'package:flutter_test/flutter_test.dart';
import 'package:fueltoken_tracker/services/token_notifications.dart';

void main() {
  test('no reminder fires before the exact expiry instant', () {
    final expiry = DateTime(2026, 10, 25, 16, 47);
    final now = DateTime(2026, 10, 25, 10);
    final slots = TokenNotifications.reminderSlots(expiry, now, days: 2);
    expect(slots, [
      DateTime(2026, 10, 25, 20),
      DateTime(2026, 10, 26, 9),
      DateTime(2026, 10, 26, 15),
      DateTime(2026, 10, 26, 20),
    ]);
  });

  test('already expired: starts at the next slot after now', () {
    final expiry = DateTime(2026, 10, 20, 16, 47);
    final now = DateTime(2026, 10, 25, 10);
    final slots = TokenNotifications.reminderSlots(expiry, now, days: 2);
    expect(slots, [
      DateTime(2026, 10, 25, 15),
      DateTime(2026, 10, 25, 20),
      DateTime(2026, 10, 26, 9),
      DateTime(2026, 10, 26, 15),
      DateTime(2026, 10, 26, 20),
    ]);
  });

  test('a reminder exactly at the expiry second is skipped', () {
    final expiry = DateTime(2026, 10, 25, 15);
    final now = DateTime(2026, 10, 25, 10);
    final slots = TokenNotifications.reminderSlots(expiry, now, days: 1);
    expect(slots, [DateTime(2026, 10, 25, 20)]);
  });

  test('the default horizon queues up to 14 days of 3-a-day nudges', () {
    final expiry = DateTime(2026, 10, 20, 16, 47);
    final now = DateTime(2026, 10, 25, 10);
    // Day 0 is partial (09:00 already passed), the next 13 days are full.
    expect(TokenNotifications.reminderSlots(expiry, now).length, 2 + 13 * 3);
  });
}
