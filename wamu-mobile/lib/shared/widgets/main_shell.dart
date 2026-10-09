import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/auth/auth_provider.dart';
import '../../features/calls/incoming_call_host.dart';
import '../../features/cart/cart_provider.dart';
import '../../features/chat/inbox_snapshot_provider.dart';
import '../../features/discover/videos_feed_visibility.dart';
import '../../features/profile/commerce_notif_provider.dart';
import '../../core/notifications/notification_sound_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/notification_settings_provider.dart';

/// Shell: Videos | Chats | Shops | Orders | You.
class MainShell extends ConsumerStatefulWidget {
  const MainShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  ConsumerState<MainShell> createState() => _MainShellState();
}

class _MainShellState extends ConsumerState<MainShell> {
  int _lastCommerceGen = 0;

  @override
  Widget build(BuildContext context) {
    final tabIndex = widget.navigationShell.currentIndex;
    // Keep videos feed in sync so background tabs don't keep playing audio/video.
    if (ref.read(shellTabIndexProvider) != tabIndex) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref.read(shellTabIndexProvider.notifier).state = tabIndex;
      });
    }

    final user = ref.watch(authProvider).user;
    final name = (user?.name.isNotEmpty == true) ? user!.name : 'You';
    final letter = name.trim().isNotEmpty ? name.trim()[0].toUpperCase() : 'Y';
    final inbox = ref.watch(inboxSnapshotProvider);
    final commerce = ref.watch(commerceNotifProvider);
    final cartCount = ref.watch(cartProvider).fold<int>(0, (n, i) => n + i.quantity);
    final onChats = widget.navigationShell.currentIndex == ShellTabs.chats;

    ref.listen<InboxSnapshot>(inboxSnapshotProvider, (prev, next) {
      if (prev != null && next.totalUnread > prev.totalUnread) {
        final prefs = ref.read(notificationSettingsProvider);
        if (prefs.messageAlerts && prefs.soundsEnabled) {
          unawaited(ref.read(notificationSoundServiceProvider).play(prefs));
        }
      }
      if (widget.navigationShell.currentIndex == ShellTabs.chats) {
        ref.read(inboxSnapshotProvider.notifier).markSeen();
        return;
      }
      if (prev == null || next.totalUnread <= prev.totalUnread) return;
      final prefs = ref.read(notificationSettingsProvider);
      if (!prefs.messageAlerts) return;
      final who = next.latestName ?? 'Someone';
      final preview = (next.latestPreview ?? 'New message').trim();
      final messenger = ScaffoldMessenger.of(context);
      messenger.clearSnackBars();
      messenger.showSnackBar(
        SnackBar(
          content: Text('$who: $preview'),
          action: SnackBarAction(
            label: 'Open',
            textColor: AppTheme.accentGreen,
            onPressed: () {
              widget.navigationShell.goBranch(ShellTabs.chats);
              ref.read(inboxSnapshotProvider.notifier).markSeen();
            },
          ),
          duration: const Duration(seconds: 4),
        ),
      );
    });

    ref.listen<CommerceNotifSnapshot>(commerceNotifProvider, (prev, next) {
      if (next.generation <= _lastCommerceGen) return;
      _lastCommerceGen = next.generation;
      final prefs = ref.read(notificationSettingsProvider);
      if (prefs.soundsEnabled) {
        unawaited(ref.read(notificationSoundServiceProvider).play(prefs));
      }
      final title = (next.latestTitle ?? 'Wamu update').trim();
      final body = (next.latestBody ?? '').trim();
      final link = next.latestDeepLink;
      final messenger = ScaffoldMessenger.of(context);
      messenger.clearSnackBars();
      messenger.showSnackBar(
        SnackBar(
          content: Text(body.isEmpty ? title : '$title — $body'),
          action: SnackBarAction(
            label: 'Open',
            textColor: AppTheme.accentGreen,
            onPressed: () async {
              final id = next.latestId;
              if (id != null && id.isNotEmpty) {
                await ref.read(commerceNotifProvider.notifier).markReadById(id);
              } else {
                await ref.read(commerceNotifProvider.notifier).markLatestRead();
              }
              if (!context.mounted) return;
              if (link != null && link.isNotEmpty) {
                context.push(link);
              } else {
                widget.navigationShell.goBranch(ShellTabs.orders);
              }
            },
          ),
          duration: const Duration(seconds: 5),
        ),
      );
    });

    return IncomingCallHost(
      child: Scaffold(
        body: widget.navigationShell,
        bottomNavigationBar: NavigationBar(
          selectedIndex: widget.navigationShell.currentIndex,
          onDestinationSelected: (i) {
            // Sync before branch so Videos feed pauses in the same frame.
            ref.read(shellTabIndexProvider.notifier).state = i;
            widget.navigationShell.goBranch(i);
            if (i == ShellTabs.chats) {
              ref.read(inboxSnapshotProvider.notifier).markSeen();
            }
            if (i == ShellTabs.you) {
              ref.read(commerceNotifProvider.notifier).markSeen();
            }
          },
          destinations: [
            const NavigationDestination(
              icon: Icon(Icons.play_circle_outline),
              selectedIcon: Icon(Icons.play_circle),
              label: 'Videos',
            ),
            NavigationDestination(
              icon: Badge(
                isLabelVisible: inbox.totalUnread > 0 && !onChats,
                label: Text('${inbox.totalUnread > 99 ? '99+' : inbox.totalUnread}'),
                child: const Icon(Icons.chat_bubble_outline),
              ),
              selectedIcon: const Icon(Icons.chat_bubble),
              label: 'Chats',
            ),
            NavigationDestination(
              icon: Badge(
                isLabelVisible: cartCount > 0,
                label: Text('$cartCount'),
                child: const Icon(Icons.storefront_outlined),
              ),
              selectedIcon: Badge(
                isLabelVisible: cartCount > 0,
                label: Text('$cartCount'),
                child: const Icon(Icons.storefront),
              ),
              label: 'Shops',
            ),
            NavigationDestination(
              icon: Badge(
                isLabelVisible: commerce.unread > 0,
                label: Text('${commerce.unread > 99 ? '99+' : commerce.unread}'),
                child: const Icon(Icons.receipt_long_outlined),
              ),
              selectedIcon: Badge(
                isLabelVisible: commerce.unread > 0,
                label: Text('${commerce.unread > 99 ? '99+' : commerce.unread}'),
                child: const Icon(Icons.receipt_long),
              ),
              label: 'Orders',
            ),
            NavigationDestination(
              icon: Badge(
                isLabelVisible: commerce.unread > 0,
                smallSize: 8,
                child: CircleAvatar(
                  radius: 12,
                  backgroundColor: AppTheme.accentGreen.withValues(alpha: 0.25),
                  child: Text(
                    letter,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.accentGreen,
                    ),
                  ),
                ),
              ),
              selectedIcon: CircleAvatar(
                radius: 12,
                backgroundColor: AppTheme.accentGreen,
                child: Text(
                  letter,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: Colors.black,
                  ),
                ),
              ),
              label: 'You',
            ),
          ],
        ),
      ),
    );
  }
}
