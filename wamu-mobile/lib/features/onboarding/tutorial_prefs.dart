import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth/auth_provider.dart';

/// Per-user product tour completion (new phone numbers must still see the tour).
const kTutorialCompletedPrefix = 'wamu_tutorial_completed_v2_';

enum TutorialStatus { unknown, needed, completed }

class TutorialController extends ChangeNotifier {
  TutorialStatus status = TutorialStatus.unknown;
  String? _userId;

  String _keyFor(String userId) => '$kTutorialCompletedPrefix$userId';

  /// Load tour state for the signed-in user. Missing key → show tour.
  Future<void> syncForUser(String? userId) async {
    final id = (userId ?? '').trim();
    if (id.isEmpty) {
      _userId = null;
      status = TutorialStatus.unknown;
      notifyListeners();
      return;
    }
    _userId = id;
    try {
      final prefs = await SharedPreferences.getInstance();
      final done = prefs.getBool(_keyFor(id)) ?? false;
      status = done ? TutorialStatus.completed : TutorialStatus.needed;
    } catch (_) {
      // Fail open to the tour for first-time UX (not silent skip).
      status = TutorialStatus.needed;
    }
    notifyListeners();
  }

  Future<void> markCompleted() async {
    final id = _userId;
    if (id != null && id.isNotEmpty) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(_keyFor(id), true);
      } catch (_) {}
    }
    status = TutorialStatus.completed;
    notifyListeners();
  }

  void clearSession() {
    _userId = null;
    status = TutorialStatus.unknown;
    notifyListeners();
  }
}

final tutorialControllerProvider = Provider<TutorialController>((ref) {
  final c = TutorialController();
  ref.onDispose(c.dispose);
  return c;
});

/// Keeps tour prefs aligned with the signed-in account (new numbers get a fresh tour).
final tutorialAuthBinderProvider = Provider<void>((ref) {
  final tutorial = ref.read(tutorialControllerProvider);
  ref.listen<AuthState>(authProvider, (prev, next) {
    if (next.status == AuthStatus.unauthenticated ||
        next.status == AuthStatus.unknown) {
      tutorial.clearSession();
      return;
    }
    final id = next.user?.id;
    if (id != null && id.isNotEmpty) {
      tutorial.syncForUser(id);
    }
  }, fireImmediately: true);
});
