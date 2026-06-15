// Basic smoke test for the BLE scanner example app.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_ble_scanner/main.dart';

void main() {
  testWidgets('App builds and shows the scanner title', (tester) async {
    await tester.pumpWidget(const BLEScannerApp());

    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.text('BLE Scanner'), findsWidgets);
  });
}
