import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:road_data_logger/main.dart';
import 'package:road_data_logger/screens/auth_screen.dart';
import 'package:road_data_logger/screens/map_screen.dart';

void main() {
  testWidgets('App smoke test - verifies initial widget build without crash', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());
    expect(find.byType(MaterialApp), findsOneWidget);
  });

  testWidgets('AuthScreen smoke test - validates Uber Clean UI elements presence', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: AuthScreen(),
      ),
    );

    expect(find.text("ROAD SENSE"), findsOneWidget);
    expect(find.text("Welcome back"), findsOneWidget);
    expect(find.text("EMAIL"), findsOneWidget);
    expect(find.text("PASSWORD"), findsOneWidget);
    expect(find.text("CONTINUE"), findsOneWidget);
  });

  testWidgets('MapScreen smoke test - validates zoom controls and nearest detection buttons', (WidgetTester tester) async {
    // Provide a larger surface so all map layers and controls fit without overflow
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: MapScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip("Locate Nearest Detection"), findsOneWidget);
    expect(find.byTooltip("Zoom In"), findsOneWidget);
    expect(find.byTooltip("Zoom Out"), findsOneWidget);
    expect(find.text("ALL REPORTS"), findsOneWidget);
    expect(find.text("MY REPORTS"), findsOneWidget);
  });
}
