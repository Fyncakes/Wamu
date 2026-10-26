import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Conversation currently on screen. Foreground pushes skip a banner for it.
final openChatIdProvider = StateProvider<String?>((ref) => null);

/// Conversation to open after a notification tap, once the user is signed in.
final pendingChatOpenProvider = StateProvider<String?>((ref) => null);
