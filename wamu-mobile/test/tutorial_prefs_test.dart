import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wamu_mobile/features/onboarding/tutorial_prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('first launch needs tutorial', () async {
    final c = TutorialController();
    await c.load();
    expect(c.status, TutorialStatus.needed);
  });

  test('markCompleted persists and does not reappear as needed', () async {
    final c = TutorialController();
    await c.load();
    expect(c.status, TutorialStatus.needed);
    await c.markCompleted();
    expect(c.status, TutorialStatus.completed);

    final again = TutorialController();
    await again.load();
    expect(again.status, TutorialStatus.completed);
  });
}
