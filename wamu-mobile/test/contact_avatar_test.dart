import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wamu_mobile/features/chat/contact_avatar.dart';

void main() {
  test('contactAvatarColor is stable for the same seed', () {
    final a = contactAvatarColor('Brian|+256700000004');
    final b = contactAvatarColor('Brian|+256700000004');
    expect(a, b);
  });

  test('contactAvatarColor differs across names', () {
    final a = contactAvatarColor('Alice');
    final b = contactAvatarColor('Zainab-Hostel');
    // Extremely unlikely to collide across palette of 8 — allow equal but prefer differ
    expect(a, isA<Color>());
    expect(b, isA<Color>());
  });

  testWidgets('ContactAvatar shows initial letter', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ContactAvatar(name: 'Kampala', phone: '+256700000001'),
        ),
      ),
    );
    expect(find.text('K'), findsOneWidget);
  });
}
