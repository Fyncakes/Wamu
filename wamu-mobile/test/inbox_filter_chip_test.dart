import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wamu_mobile/core/theme/app_theme.dart';
import 'package:wamu_mobile/features/chat/inbox_filter_chip.dart';

void main() {
  testWidgets('InboxFilterChip light selected uses soft green', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.messengerLightTheme,
        home: Scaffold(
          body: InboxFilterChip(
            label: 'Unread',
            selected: true,
            onTap: () {},
          ),
        ),
      ),
    );
    expect(find.text('Unread'), findsOneWidget);
    final chip = tester.widget<FilterChip>(find.byType(FilterChip));
    expect(chip.selectedColor, const Color(0xFFD7F5E5));
  });

  testWidgets('InboxFilterChip dark unselected uses elevated surface', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        themeMode: ThemeMode.dark,
        theme: AppTheme.messengerLightTheme,
        darkTheme: AppTheme.messengerDarkTheme,
        home: Scaffold(
          body: InboxFilterChip(
            label: 'Groups',
            selected: false,
            onTap: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Groups'), findsOneWidget);
    final chip = tester.widget<FilterChip>(find.byType(FilterChip));
    expect(chip.backgroundColor, AppTheme.messengerElevated);
  });
}
