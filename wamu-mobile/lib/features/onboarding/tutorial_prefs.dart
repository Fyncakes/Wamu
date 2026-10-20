import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Local persistence for the first-run product tour (not tied to auth tokens).
const kTutorialCompletedKey = 'wamu_tutorial_completed_v1';

enum TutorialStatus { unknown, needed, completed }

class TutorialController extends ChangeNotifier {
  TutorialStatus status = TutorialStatus.unknown;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final done = prefs.getBool(kTutorialCompletedKey) ?? false;
      status = done ? TutorialStatus.completed : TutorialStatus.needed;
    } catch (_) {
      // If prefs fail, don't trap the user — treat as completed.
      status = TutorialStatus.completed;
    }
    notifyListeners();
  }

  Future<void> markCompleted() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(kTutorialCompletedKey, true);
    } catch (_) {}
    status = TutorialStatus.completed;
    notifyListeners();
  }

  /// Allows Settings / Help to reopen the tour without clearing "completed".
  void openReplay() {
    // Replay is route-driven (`?replay=1`); status stays completed.
    notifyListeners();
  }
}

final tutorialControllerProvider = Provider<TutorialController>((ref) {
  final c = TutorialController();
  c.load();
  ref.onDispose(c.dispose);
  return c;
});
