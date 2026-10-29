import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:fueltoken_tracker/db/database_helper.dart';
import 'package:fueltoken_tracker/models/token_record.dart';

TokenRecord tok(
  String id,
  String code,
  String plate, {
  String? name,
  String? cnic,
  DateTime? imported,
}) {
  final when = imported ?? DateTime.now();
  return TokenRecord(
    id: id,
    tokenCode: code,
    vehicleNumber: plate,
    vehicleType: VehicleType.motorcycle,
    personName: name,
    cnic: cnic,
    status: TokenStatus.active,
    dateReceived: when,
    dateImported: when,
    subsidyAmount: 500,
    fuelLitres: 20,
  );
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  // The test DB lives on disk and is shared by every suite, so each test uses
  // its own plate/codes derived from this run's timestamp.
  final stamp = DateTime.now().microsecondsSinceEpoch;
  String plate(int n) => 'OW$stamp-$n';

  test('vehicleOwnerFor returns the freshest non-empty name/CNIC per plate',
      () async {
    final db = DatabaseHelper();
    final p = plate(1);
    await db.insertToken(tok('vo-1a-$stamp', '8100000001', p,
        name: 'Ali', cnic: '42101-1234567-1', imported: DateTime(2026, 1, 1)));
    await db.insertToken(tok('vo-1b-$stamp', '8100000002', p,
        name: 'Ali Raza', imported: DateTime(2026, 2, 1)));

    // Spaces/dashes/case must not matter when matching the plate.
    final messy = ' ${p.toLowerCase().replaceAll('-', ' ')} ';
    final owner = await db.vehicleOwnerFor(messy);

    expect(owner, isNotNull);
    expect(owner!.personName, 'Ali Raza');
    expect(owner.cnic, '42101-1234567-1');
  });

  test('a new token inherits owner name/CNIC from the plate history', () async {
    final db = DatabaseHelper();
    final p = plate(2);
    await db.insertToken(tok('vo-2a-$stamp', '8100000011', p,
        name: 'Bilal',
        cnic: '35202-7654321-9',
        imported: DateTime(2026, 3, 1)));

    final fresh = tok('vo-2b-$stamp', '8100000012', p,
        imported: DateTime(2026, 3, 8));
    await db.insertToken(fresh);

    final saved =
        (await db.getAllTokens()).firstWhere((t) => t.id == fresh.id);
    expect(saved.personName, 'Bilal');
    expect(saved.cnic, '35202-7654321-9');
  });

  test('owner details added later fill blanks without overwriting', () async {
    final db = DatabaseHelper();
    final p = plate(3);
    final first = tok('vo-3a-$stamp', '8100000021', p,
        imported: DateTime(2026, 4, 1));
    final second = tok('vo-3b-$stamp', '8100000022', p,
        name: 'Existing', imported: DateTime(2026, 4, 8));
    await db.insertToken(first);
    await db.insertToken(second);

    // The user edits the PAST token and adds owner details there.
    await db.updateToken(first.copyWith(
      personName: 'Sana',
      cnic: '61101-1112223-4',
    ));

    final all = await db.getAllTokens();
    final a = all.firstWhere((t) => t.id == first.id);
    final b = all.firstWhere((t) => t.id == second.id);

    expect(a.personName, 'Sana');
    expect(a.cnic, '61101-1112223-4');
    expect(b.personName, 'Existing', reason: 'never overwrite a known value');
    expect(b.cnic, '61101-1112223-4', reason: 'blank sibling is filled');
  });

  test('owner details never leak across different vehicles', () async {
    final db = DatabaseHelper();
    final p1 = plate(4);
    final p2 = plate(5);
    await db.insertToken(tok('vo-4a-$stamp', '8100000031', p1,
        name: 'Owner A', cnic: '11111-1111111-1'));
    final other = tok('vo-4b-$stamp', '8100000032', p2);
    await db.insertToken(other);

    final saved =
        (await db.getAllTokens()).firstWhere((t) => t.id == other.id);
    expect(saved.personName, isNull);
    expect(saved.cnic, isNull);
  });
}
