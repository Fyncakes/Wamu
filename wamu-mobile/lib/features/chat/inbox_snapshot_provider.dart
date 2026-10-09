import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Cross-tab inbox signal — unread total + last preview for banners.
class InboxSnapshot {
  const InboxSnapshot({this.totalUnread = 0, this.latestPreview, this.latestName});

  final int totalUnread;
  final String? latestPreview;
  final String? latestName;
}

class InboxNotifier extends StateNotifier<InboxSnapshot> {
  InboxNotifier() : super(const InboxSnapshot());

  int _lastAnnounced = 0;

  /// Returns true if unread rose since last announce (for SnackBar).
  bool updateFromConversations(List<({int unread, String name, String? preview, bool muted})> rows) {
    var total = 0;
    String? name;
    String? preview;
    for (final r in rows) {
      if (r.muted) continue;
      total += r.unread;
      if (r.unread > 0 && (preview == null || preview.isEmpty)) {
        name = r.name;
        preview = r.preview;
      }
    }
    final rose = total > _lastAnnounced && total > state.totalUnread;
    state = InboxSnapshot(totalUnread: total, latestPreview: preview, latestName: name);
    if (rose) {
      _lastAnnounced = total;
      return true;
    }
    if (total < _lastAnnounced) _lastAnnounced = total;
    return false;
  }

  void markSeen() {
    _lastAnnounced = state.totalUnread;
  }
}

final inboxSnapshotProvider =
    StateNotifierProvider<InboxNotifier, InboxSnapshot>((ref) => InboxNotifier());
