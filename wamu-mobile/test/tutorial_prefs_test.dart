import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wamu_mobile/features/onboarding/tutorial_prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('new user id needs tutorial', () async {
    final c = TutorialController();
    await c.syncForUser('user-a');
    expect(c.status, TutorialStatus.needed);
  });

  test('completion is per user — other numbers still see the tour', () async {
    final c = TutorialController();
    await c.syncForUser('user-a');
    await c.markCompleted();
    expect(c.status, TutorialStatus.completed);

    await c.syncForUser('user-b');
    expect(c.status, TutorialStatus.needed);

    await c.syncForUser('user-a');
    expect(c.status, TutorialStatus.completed);
  });

  test('clearSession is idle so splash can reach login', () async {
    final c = TutorialController();
    await c.syncForUser('user-a');
    await c.markCompleted();
    c.clearSession();
    expect(c.status, TutorialStatus.completed);
  });
}
