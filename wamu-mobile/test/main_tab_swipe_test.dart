import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wamu_mobile/shared/widgets/main_tab_swipe.dart';

void main() {
  testWidgets('horizontal swipe moves to the next main tab', (tester) async {
    var index = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MainTabSwipe(
            currentIndex: 0,
            onIndexChanged: (i) => index = i,
            children: const [
              ColoredBox(color: Colors.red, child: SizedBox.expand()),
              ColoredBox(color: Colors.green, child: SizedBox.expand()),
              ColoredBox(color: Colors.blue, child: SizedBox.expand()),
              ColoredBox(color: Colors.orange, child: SizedBox.expand()),
            ],
          ),
        ),
      ),
    );
    await tester.drag(find.byType(PageView), const Offset(-500, 0));
    await tester.pumpAndSettle();
    expect(index, 1);
  });
}
