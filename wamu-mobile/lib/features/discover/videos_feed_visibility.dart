import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Main shell tab indexes — Videos | Chats | Shops | Orders | You.
abstract final class ShellTabs {
  static const videos = 0;
  static const chats = 1;
  static const shops = 2;
  static const orders = 3;
  static const you = 4;
}

final shellTabIndexProvider = StateProvider<int>((ref) => ShellTabs.videos);

/// True when the Videos tab is selected (feed may still be covered by a pushed route).
final videosTabSelectedProvider = Provider<bool>((ref) {
  return ref.watch(shellTabIndexProvider) == ShellTabs.videos;
});
