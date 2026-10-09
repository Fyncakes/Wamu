import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_provider.dart';
import '../profile/notifications_screen.dart';

/// Commerce / ops notification types surfaced in the shell (not chat).
const kCommerceNotificationTypes = {
  'NEW_ORDER',
  'ORDER_PAID',
  'ORDER_STATUS',
  'ORDER_DISPUTE',
  'BUSINESS_VERIFIED',
  'PAYMENT_SUCCESS',
  'DELIVERY_ASSIGNED',
  'DELIVERY_AVAILABLE',
  'DELIVERY_JOB',
  'PAYOUT_SUCCESS',
  'PAYOUT_REVERSED',
  'DELIVERY_CANCELLED',
};

bool isCommerceNotificationType(String type) =>
    kCommerceNotificationTypes.contains(type.toUpperCase());

class CommerceNotifSnapshot {
  const CommerceNotifSnapshot({
    this.unread = 0,
    this.latestTitle,
    this.latestBody,
    this.latestDeepLink,
    this.latestId,
    this.generation = 0,
  });

  final int unread;
  final String? latestTitle;
  final String? latestBody;
  final String? latestDeepLink;
  final String? latestId;
  /// Bumps when a *new* unread commerce notification appears (for snackbars).
  final int generation;
}

class CommerceNotifNotifier extends StateNotifier<CommerceNotifSnapshot> {
  CommerceNotifNotifier(this._ref) : super(const CommerceNotifSnapshot()) {
    _ref.listen<AuthState>(authProvider, (prev, next) {
      if (next.user == null) {
        _poll?.cancel();
        _seenIds.clear();
        state = const CommerceNotifSnapshot();
        return;
      }
      _refresh();
      _ensurePoll();
    });
    if (_ref.read(authProvider).user != null) {
      _refresh();
      _ensurePoll();
    }
  }

  final Ref _ref;
  Timer? _poll;
  final Set<String> _seenIds = {};
  bool _seeded = false;

  void _ensurePoll() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 8), (_) => _refresh());
  }

  Future<void> _refresh() async {
    if (_ref.read(authProvider).user == null) return;
    try {
      final rows = await _ref.read(notificationsRepositoryProvider).list();
      final commerce = rows.where((n) => isCommerceNotificationType(n.type)).toList();
      final unreadRows = commerce.where((n) => !n.isRead).toList();
      final unread = unreadRows.length;

      NotificationModel? latest;
      for (final n in unreadRows) {
        latest = n;
        break; // API returns newest first typically
      }
      // Prefer truly newest unread by createdAt if present
      if (unreadRows.length > 1) {
        unreadRows.sort((a, b) => (b.createdAt ?? '').compareTo(a.createdAt ?? ''));
        latest = unreadRows.first;
      }

      var generation = state.generation;
      if (!_seeded) {
        for (final n in unreadRows) {
          _seenIds.add(n.id);
        }
        _seeded = true;
      } else if (latest != null && !_seenIds.contains(latest.id)) {
        _seenIds.add(latest.id);
        generation += 1;
      }

      state = CommerceNotifSnapshot(
        unread: unread,
        latestTitle: latest?.title,
        latestBody: latest?.body,
        latestDeepLink: latest?.deepLink,
        latestId: latest?.id,
        generation: generation,
      );
    } catch (_) {
      // Offline / 401 — keep last snapshot
    }
  }

  Future<void> refresh() => _refresh();

  Future<void> markLatestRead() async {
    final id = state.latestId;
    if (id == null || id.isEmpty) return;
    await markReadById(id);
  }

  /// Marks one notification read and clears it from the shell badge immediately.
  Future<void> markReadById(String id) async {
    if (id.isEmpty) return;
    _seenIds.add(id);
    final nextUnread = state.unread > 0 ? state.unread - 1 : 0;
    state = CommerceNotifSnapshot(
      unread: nextUnread,
      latestTitle: nextUnread == 0 ? null : state.latestTitle,
      latestBody: nextUnread == 0 ? null : state.latestBody,
      latestDeepLink: nextUnread == 0 ? null : state.latestDeepLink,
      latestId: nextUnread == 0 ? null : state.latestId,
      generation: state.generation,
    );
    try {
      await _ref.read(notificationsRepositoryProvider).markRead(id);
    } catch (_) {}
    await _refresh();
  }

  void markSeen() {
    // Suppress further snackbars for current unread set without hitting API.
    final id = state.latestId;
    if (id != null) _seenIds.add(id);
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }
}

final commerceNotifProvider =
    StateNotifierProvider<CommerceNotifNotifier, CommerceNotifSnapshot>((ref) {
  return CommerceNotifNotifier(ref);
});
