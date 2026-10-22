import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fueltoken_tracker/models/token_record.dart';
import 'package:fueltoken_tracker/widgets/active_token_card.dart';

void main() {
  testWidgets('ActiveTokenCard displays token number, vehicle, and one-time use button', (WidgetTester tester) async {
    final token = TokenRecord(
      id: 'test-1',
      tokenCode: '8401712225',
      vehicleNumber: 'NFF-2364',
      vehicleType: VehicleType.motorcycle,
      status: TokenStatus.active,
      dateReceived: DateTime.now(),
      dateImported: DateTime.now(),
      expiryDate: DateTime.now().add(const Duration(days: 3)),
      subsidyAmount: 500.0,
    );

    bool usedClicked = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ActiveTokenCard(
            token: token,
            onUseToken: () {
              usedClicked = true;
            },
          ),
        ),
      ),
    );

    // Verify token code is masked in card and vehicle plate is rendered
    expect(find.text('840 •••• 225'), findsOneWidget);
    expect(find.text('NFF-2364'), findsOneWidget);
    expect(find.text('TOKEN NUMBER  ·  Rs. 500 RELIEF'), findsOneWidget);
    expect(find.text('USE TOKEN  ·  ONE-TIME'), findsOneWidget);

    // Tap the button
    await tester.tap(find.text('USE TOKEN  ·  ONE-TIME'));
    await tester.pump();

    expect(usedClicked, isTrue);
  });
}
