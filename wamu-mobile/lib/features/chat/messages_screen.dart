import 'dart:async';
import 'dart:convert';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../core/media/data_saver_image.dart';
import '../../core/media_url.dart';
import '../../core/network/api_error.dart';
import '../../core/storage/chat_kv_provider.dart';
import '../../core/storage/kv_store.dart';
import '../../core/storage/secure_kv_store.dart';
import '../../core/storage/secure_storage.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/models/chat_model.dart';
import '../../shared/models/product_model.dart';
import '../../shared/utils/inbox_preview.dart';
import '../../shared/utils/phone_normalize.dart';
import '../../shared/utils/ugx_formatter.dart';
import '../../shared/widgets/error_view.dart';
import '../../shared/widgets/loading_view.dart';
import '../../shared/widgets/momo_provider_picker.dart';
import '../auth/auth_provider.dart';
import '../business_owner/owner_products_repository.dart';
import '../calls/active_call_screen.dart';
import '../calls/calls_repository.dart';
import '../home/catalog_repository.dart';
import '../orders/orders_repository.dart';
import 'chat_image_editor.dart';
import 'chat_media_grid.dart';
import 'chat_media_image.dart';
import 'receipt_composer_sheet.dart';
import 'chat_repository.dart';
import 'chat_voice_note.dart';
import 'chat_wallpaper.dart';
import 'contact_avatar.dart';
import 'document_pick.dart';
import 'inbox_snapshot_provider.dart';
import '../discover/videos_feed_visibility.dart';
import 'local_message_cache.dart';
import 'media_outbox.dart';
import 'message_outbox.dart';
import 'inbox_filter_chip.dart';
import 'webcam_capture.dart';

enum _ChatFilter { all, unread, favourites, groups, archived }

/// Chats inbox — WhatsApp-parity Sprint 1 home + Phase D prefs.
class MessagesScreen extends ConsumerStatefulWidget {
  const MessagesScreen({super.key});

  @override
  ConsumerState<MessagesScreen> createState() => _MessagesScreenState();
}

class _MessagesScreenState extends ConsumerState<MessagesScreen> {
  late Future<List<ConversationModel>> _future;
  final _searchCtrl = TextEditingController();
  _ChatFilter _filter = _ChatFilter.all;
  String _query = '';
  List<ConversationModel> _cached = [];
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    _load();
    // Live-ish inbox — only while Chats tab is selected (IndexedStack stays mounted).
    _pollTimer = Timer.periodic(const Duration(seconds: 8), (_) {
      if (!mounted) return;
      if (ref.read(shellTabIndexProvider) != ShellTabs.chats) return;
      _silentRefresh();
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _load() {
    _future = ref.read(chatRepositoryProvider).getConversations().then((list) {
      _cached = list;
      return list;
    });
  }

  Future<void> _silentRefresh() async {
    try {
      final list = await ref.read(chatRepositoryProvider).getConversations();
      if (!mounted) return;
      final rose = ref.read(inboxSnapshotProvider.notifier).updateFromConversations([
        for (final c in list)
          (
            unread: c.unreadCount,
            name: c.displayName,
            preview: c.lastMessagePreview,
            muted: c.muted,
          ),
      ]);
      // Avoid flicker when nothing changed
      final changed = list.length != _cached.length ||
          list.asMap().entries.any((e) {
            if (e.key >= _cached.length) return true;
            final a = e.value;
            final b = _cached[e.key];
            return a.id != b.id ||
                a.lastMessagePreview != b.lastMessagePreview ||
                a.unreadCount != b.unreadCount ||
                a.lastMessageAt != b.lastMessageAt ||
                a.lastMessageStatus != b.lastMessageStatus ||
                a.avatarUrl != b.avatarUrl;
          });
      if (changed) {
        setState(() {
          _cached = list;
          _future = Future.value(list);
        });
      }
      // rose is consumed by MainShell via provider watch
      if (rose) {
        // no-op here — MainShell listens
      }
    } catch (_) {}
  }

  Future<void> _setPref(
    ConversationModel conv, {
    bool? muted,
    bool? pinned,
    bool? archived,
    bool? favourite,
  }) async {
    try {
      final updated = await ref.read(chatRepositoryProvider).updatePrefs(
            conv.id,
            muted: muted,
            pinned: pinned,
            archived: archived,
            favourite: favourite,
          );
      setState(() {
        _cached = [
          for (final c in _cached)
            if (c.id == updated.id) updated else c,
        ];
        // Keep pinned sort locally
        _cached.sort((a, b) {
          if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
          return 0;
        });
        _future = Future.value(_cached);
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _hideConversationFromInbox(ConversationModel conv) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Delete chat?'),
        content: const Text(
          'This chat leaves your inbox only. They keep their copy. No notification is sent.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(d, true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(chatRepositoryProvider).hideConversation(conv.id);
      if (!mounted) return;
      setState(() {
        _cached = [for (final c in _cached) if (c.id != conv.id) c];
        _future = Future.value(_cached);
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _showChatActions(ConversationModel conv) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppTheme.messengerElevated,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(conv.favourite ? Icons.star : Icons.star_outline),
              title: Text(conv.favourite ? 'Remove favourite' : 'Favourite'),
              onTap: () => Navigator.pop(ctx, 'favourite'),
            ),
            ListTile(
              leading: Icon(conv.pinned ? Icons.push_pin : Icons.push_pin_outlined),
              title: Text(conv.pinned ? 'Unpin' : 'Pin to top'),
              onTap: () => Navigator.pop(ctx, 'pin'),
            ),
            ListTile(
              leading: Icon(conv.muted ? Icons.notifications_active_outlined : Icons.notifications_off_outlined),
              title: Text(conv.muted ? 'Unmute' : 'Mute notifications'),
              onTap: () => Navigator.pop(ctx, 'mute'),
            ),
            ListTile(
              leading: Icon(conv.archived ? Icons.unarchive_outlined : Icons.archive_outlined),
              title: Text(conv.archived ? 'Unarchive' : 'Archive'),
              onTap: () => Navigator.pop(ctx, 'archive'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
              title: const Text('Delete chat', style: TextStyle(color: Colors.redAccent)),
              subtitle: const Text('Only on this phone. They won’t be notified.'),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (action == null) return;
    switch (action) {
      case 'favourite':
        await _setPref(conv, favourite: !conv.favourite);
      case 'pin':
        await _setPref(conv, pinned: !conv.pinned);
      case 'mute':
        await _setPref(conv, muted: !conv.muted);
      case 'archive':
        await _setPref(conv, archived: !conv.archived);
      case 'delete':
        await _hideConversationFromInbox(conv);
    }
  }

  String _timeLabel(String? iso) {
    if (iso == null || iso.isEmpty) return '';
    try {
      final dt = DateTime.parse(iso).toLocal();
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final day = DateTime(dt.year, dt.month, dt.day);
      final diff = today.difference(day).inDays;
      if (diff == 0) {
        final h = dt.hour.toString().padLeft(2, '0');
        final m = dt.minute.toString().padLeft(2, '0');
        return '$h:$m';
      }
      if (diff == 1) return 'Yesterday';
      if (diff < 7) {
        const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
        return days[dt.weekday - 1];
      }
      return '${dt.day}/${dt.month}/${dt.year % 100}';
    } catch (_) {
      return '';
    }
  }

  /// Rich preview: photo / voice / document / reaction from last-message text.
  Widget _previewRow(ConversationModel conv, ThemeData theme) {
    final raw = (conv.lastMessagePreview ?? '').trim();
    final parts = formatInboxPreview(raw.isEmpty && conv.isGroup && conv.memberCount > 0
        ? '${conv.memberCount} members'
        : raw);
    IconData? leadingIcon;
    switch (parts.kind) {
      case InboxPreviewKind.photo:
        leadingIcon = Icons.photo_outlined;
      case InboxPreviewKind.voice:
        leadingIcon = Icons.mic_none;
      case InboxPreviewKind.document:
        leadingIcon = Icons.insert_drive_file_outlined;
      case InboxPreviewKind.reaction:
        leadingIcon = Icons.emoji_emotions_outlined;
      case InboxPreviewKind.text:
        leadingIcon = null;
    }
    final text = parts.text;

    Widget? tick;
    if (conv.lastMessageFromMe &&
        raw.isNotEmpty &&
        parts.kind != InboxPreviewKind.reaction) {
      final s = (conv.lastMessageStatus ?? 'SENT').toUpperCase();
      if (s == 'READ') {
        tick = const Icon(Icons.done_all, size: 15, color: Color(0xFF53BDEB));
      } else if (s == 'DELIVERED') {
        tick = Icon(Icons.done_all, size: 15, color: AppTheme.messengerMuted.withValues(alpha: 0.9));
      } else {
        tick = Icon(Icons.done, size: 15, color: AppTheme.messengerMuted.withValues(alpha: 0.9));
      }
    }

    return Row(
      children: [
        if (conv.muted) ...[
          const Icon(Icons.volume_off, size: 14, color: AppTheme.messengerMuted),
          const SizedBox(width: 4),
        ],
        if (tick != null) ...[
          tick,
          const SizedBox(width: 3),
        ],
        if (leadingIcon != null) ...[
          Icon(leadingIcon, size: 16, color: AppTheme.messengerMuted),
          const SizedBox(width: 4),
        ],
        Expanded(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: conv.unreadCount > 0 ? AppTheme.messengerText : AppTheme.messengerMuted,
              fontWeight: conv.unreadCount > 0 ? FontWeight.w500 : FontWeight.w400,
            ),
          ),
        ),
      ],
    );
  }

  List<ConversationModel> _applyFilters(List<ConversationModel> all) {
    var list = all;
    switch (_filter) {
      case _ChatFilter.unread:
        list = list.where((c) => !c.archived && c.unreadCount > 0).toList();
      case _ChatFilter.favourites:
        list = list.where((c) => !c.archived && c.favourite).toList();
      case _ChatFilter.groups:
        list = list.where((c) => !c.archived && c.isGroup).toList();
      case _ChatFilter.archived:
        list = list.where((c) => c.archived).toList();
      case _ChatFilter.all:
        list = list.where((c) => !c.archived).toList();
    }
    final q = _query.trim().toLowerCase();
    if (q.isNotEmpty) {
      list = list
          .where((c) =>
              c.displayName.toLowerCase().contains(q) ||
              (c.lastMessagePreview ?? '').toLowerCase().contains(q) ||
              (c.participantPhone ?? '').contains(q))
          .toList();
    }
    return list;
  }

  void _showOverflow() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.messengerElevated,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.group_add_outlined),
              title: const Text('New group'),
              onTap: () {
                Navigator.pop(ctx);
                context.push('/chats/new');
              },
            ),
            ListTile(
              leading: const Icon(Icons.campaign_outlined),
              title: const Text('New community'),
              onTap: () {
                Navigator.pop(ctx);
                context.go('/communities');
              },
            ),
            ListTile(
              leading: const Icon(Icons.archive_outlined),
              title: const Text('Archived chats'),
              onTap: () {
                Navigator.pop(ctx);
                setState(() => _filter = _ChatFilter.archived);
              },
            ),
            ListTile(
              leading: const Icon(Icons.settings_outlined),
              title: const Text('Settings'),
              onTap: () {
                Navigator.pop(ctx);
                context.go('/settings');
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: TextButton(
          onPressed: () {
            // Brand → shops home
            context.go('/home');
          },
          style: TextButton.styleFrom(
            foregroundColor: AppTheme.accentGreen,
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            minimumSize: const Size(64, 40),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            alignment: Alignment.centerLeft,
          ),
          child: Text(
            'Wamu',
            style: theme.textTheme.titleLarge?.copyWith(
              color: AppTheme.accentGreen,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.2,
            ),
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'New chat',
            onPressed: () => context.push('/chats/new'),
            icon: const Icon(Icons.chat_bubble_outline),
          ),
          IconButton(
            tooltip: 'More',
            onPressed: _showOverflow,
            icon: const Icon(Icons.more_vert),
          ),
        ],
      ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          FloatingActionButton.small(
            heroTag: 'wamu_ai_fab',
            backgroundColor: Theme.of(context).brightness == Brightness.dark
                ? AppTheme.messengerElevated
                : const Color(0xFFF0F2F5),
            foregroundColor: AppTheme.accentGreen,
            onPressed: () => context.push('/ai'),
            child: const Icon(Icons.smart_toy_outlined),
          ),
          const SizedBox(height: 12),
          FloatingActionButton(
            heroTag: 'wamu_new_chat_fab',
            onPressed: () async {
              await context.push('/chats/new');
              if (mounted) setState(_load);
            },
            child: const Icon(Icons.add, size: 28),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: TextField(
              controller: _searchCtrl,
              onChanged: (v) => setState(() => _query = v),
              textInputAction: TextInputAction.search,
              onSubmitted: (v) {
                final q = v.trim();
                if (q.isEmpty) return;
                context.push('/ai', extra: q);
              },
              style: theme.textTheme.bodyLarge,
              decoration: InputDecoration(
                hintText: 'Ask Wamu or Search',
                prefixIcon: Icon(
                  Icons.search,
                  color: Theme.of(context).brightness == Brightness.dark
                      ? AppTheme.messengerMuted
                      : const Color(0xFF667781),
                ),
              ),
            ),
          ),
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                InboxFilterChip(
                  label: 'All',
                  selected: _filter == _ChatFilter.all,
                  onTap: () => setState(() => _filter = _ChatFilter.all),
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ActionChip(
                    avatar: const Icon(
                      Icons.smart_toy_outlined,
                      size: 16,
                      color: AppTheme.accentGreen,
                    ),
                    label: const Text('Ask Wamu'),
                    onPressed: () {
                      final q = _searchCtrl.text.trim();
                      context.push('/ai', extra: q.isEmpty ? null : q);
                    },
                    backgroundColor: Theme.of(context).brightness == Brightness.dark
                        ? AppTheme.messengerElevated
                        : const Color(0xFFF0F2F5),
                    side: BorderSide.none,
                    visualDensity: VisualDensity.compact,
                  ),
                ),
                InboxFilterChip(
                  label: 'Unread',
                  selected: _filter == _ChatFilter.unread,
                  onTap: () => setState(() => _filter = _ChatFilter.unread),
                ),
                InboxFilterChip(
                  label: 'Favourites',
                  selected: _filter == _ChatFilter.favourites,
                  onTap: () => setState(() => _filter = _ChatFilter.favourites),
                ),
                InboxFilterChip(
                  label: 'Groups',
                  selected: _filter == _ChatFilter.groups,
                  onTap: () => setState(() => _filter = _ChatFilter.groups),
                ),
                InboxFilterChip(
                  label: 'Archived',
                  selected: _filter == _ChatFilter.archived,
                  onTap: () => setState(() => _filter = _ChatFilter.archived),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: FutureBuilder<List<ConversationModel>>(
              future: _future,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting && _cached.isEmpty) {
                  return const LoadingView();
                }
                if (snapshot.hasError && _cached.isEmpty) {
                  return ErrorView(
                    message: '${snapshot.error}',
                    onRetry: () => setState(_load),
                  );
                }
                final all = snapshot.data ?? _cached;
                final conversations = _applyFilters(all);

                if (all.where((c) => !c.archived).isEmpty && _filter != _ChatFilter.archived) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.forum_outlined, size: 64, color: theme.colorScheme.primary),
                          const SizedBox(height: 16),
                          Text('Your chats live here', style: theme.textTheme.titleLarge),
                          const SizedBox(height: 8),
                          Text(
                            'Start a DM with any +256 number on Wamu.\n'
                            'Try Brian: +256700000004',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyMedium,
                          ),
                          const SizedBox(height: 20),
                          ElevatedButton.icon(
                            onPressed: () => context.push('/chats/new'),
                            icon: const Icon(Icons.add),
                            label: const Text('New chat'),
                          ),
                        ],
                      ),
                    ),
                  );
                }

                if (conversations.isEmpty) {
                  return Center(
                    child: Text(
                      _filter == _ChatFilter.archived
                          ? 'No archived chats'
                          : _filter == _ChatFilter.favourites
                              ? 'Long-press a chat to favourite'
                              : 'No chats in this filter',
                      style: theme.textTheme.bodyMedium,
                    ),
                  );
                }

                return RefreshIndicator(
                  color: AppTheme.accentGreen,
                  onRefresh: () async => setState(_load),
                  child: ListView.builder(
                    itemCount: conversations.length,
                    itemBuilder: (context, index) {
                      final conv = conversations[index];
                      return InkWell(
                        onTap: () async {
                          await context.push('/chat/${conv.id}');
                          if (mounted) setState(_load);
                        },
                        onLongPress: () => _showChatActions(conv),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Stack(
                                children: [
                                  ConversationAvatar(conversation: conv, radius: 26),
                                  if (conv.favourite)
                                    Positioned(
                                      right: 0,
                                      bottom: 0,
                                      child: Container(
                                        padding: const EdgeInsets.all(2),
                                        decoration: const BoxDecoration(
                                          color: AppTheme.messengerBg,
                                          shape: BoxShape.circle,
                                        ),
                                        child: const Icon(
                                          Icons.star,
                                          size: 12,
                                          color: AppTheme.accentGreen,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        if (conv.pinned) ...[
                                          const Icon(
                                            Icons.push_pin,
                                            size: 14,
                                            color: AppTheme.messengerMuted,
                                          ),
                                          const SizedBox(width: 4),
                                        ],
                                        Expanded(
                                          child: Text(
                                            conv.displayName,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: theme.textTheme.titleMedium?.copyWith(
                                              fontWeight: conv.unreadCount > 0
                                                  ? FontWeight.w700
                                                  : FontWeight.w500,
                                            ),
                                          ),
                                        ),
                                        Text(
                                          _timeLabel(conv.lastMessageAt),
                                          style: theme.textTheme.bodySmall?.copyWith(
                                            color: conv.unreadCount > 0
                                                ? AppTheme.accentGreen
                                                : AppTheme.messengerMuted,
                                            fontWeight: conv.unreadCount > 0
                                                ? FontWeight.w600
                                                : FontWeight.w400,
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    Row(
                                      children: [
                                        Expanded(child: _previewRow(conv, theme)),
                                        if (conv.unreadCount > 0) ...[
                                          const SizedBox(width: 8),
                                          Container(
                                            constraints: const BoxConstraints(minWidth: 22),
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 6,
                                              vertical: 2,
                                            ),
                                            decoration: BoxDecoration(
                                              color: AppTheme.accentGreen,
                                              borderRadius: BorderRadius.circular(12),
                                            ),
                                            child: Text(
                                              '${conv.unreadCount}',
                                              textAlign: TextAlign.center,
                                              style: const TextStyle(
                                                fontSize: 11,
                                                fontWeight: FontWeight.w700,
                                                color: Colors.black,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class NewChatScreen extends ConsumerStatefulWidget {
  const NewChatScreen({super.key});

  @override
  ConsumerState<NewChatScreen> createState() => _NewChatScreenState();
}

class _NewChatScreenState extends ConsumerState<NewChatScreen> {
  final _phoneController = TextEditingController(text: '+256');
  final _searchController = TextEditingController();
  bool _loading = false;
  bool _dirLoading = true;
  String? _error;
  String _query = '';
  List<Map<String, dynamic>> _people = [];
  int _onWamuCount = 0;

  static const _inviteSuggestions = [
    ('Mum', '+256700111222'),
    ('Hostel mate', '+256701222333'),
    ('Class group lead', '+256702333444'),
  ];

  @override
  void initState() {
    super.initState();
    _loadDirectory();
  }

  @override
  void dispose() {
    _phoneController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadDirectory() async {
    setState(() => _dirLoading = true);
    try {
      final dir = await ref.read(chatRepositoryProvider).getDirectory();
      if (!mounted) return;
      setState(() {
        _people = dir.items;
        _onWamuCount = dir.onWamuCount;
        _dirLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _dirLoading = false;
      });
    }
  }

  Future<void> _start({String? phone, String? userId}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final convo = await ref.read(chatRepositoryProvider).startDirectChat(
            peerPhone: phone != null ? normalizeUgPhone(phone) : null,
            peerUserId: userId,
            message: 'Hey — connected on Wamu 👋',
          );
      if (!mounted) return;
      context.pop();
      context.push('/chat/${convo.id}');
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _lookupAndStart() async {
    final phone = normalizeUgPhone(_phoneController.text);
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final found = await ref.read(chatRepositoryProvider).lookupByPhone(phone);
      if (found == null) {
        if (!mounted) return;
        setState(() => _loading = false);
        await _invite(phone);
        return;
      }
      await _start(userId: found['id']?.toString(), phone: phone);
    } catch (e) {
      setState(() => _error = '$e');
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _invite(String phone) async {
    final digits = phone.replaceAll(RegExp(r'[^\d+]'), '');
    final message =
        'Join me on Wamu — Uganda’s digital home for chat, discover & pay. '
        'Sign up with your +256 number and find me. https://wamu.ug';
    if (!mounted) return;
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppTheme.messengerElevated,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: ContactAvatar(name: phone, phone: phone, radius: 22),
              title: Text('$phone isn’t on Wamu yet'),
              subtitle: const Text('Invite them by SMS or share a link'),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.sms_outlined, color: AppTheme.accentGreen),
              title: const Text('Send SMS'),
              onTap: () => Navigator.pop(ctx, 'sms'),
            ),
            ListTile(
              leading: const Icon(Icons.ios_share, color: AppTheme.accentGreen),
              title: const Text('Share invite'),
              onTap: () => Navigator.pop(ctx, 'share'),
            ),
            ListTile(
              leading: const Icon(Icons.copy_outlined, color: AppTheme.messengerMuted),
              title: const Text('Copy invite text'),
              onTap: () => Navigator.pop(ctx, 'copy'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == 'sms') {
      // Works on Android/iOS; falls back to system share if SMS app missing.
      final uri = Uri.parse(
        'sms:$digits?body=${Uri.encodeComponent(message)}',
      );
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok && mounted) {
        await SharePlus.instance.share(ShareParams(text: message));
      }
    } else if (choice == 'share') {
      await SharePlus.instance.share(ShareParams(text: message));
    } else {
      await Clipboard.setData(ClipboardData(text: message));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Invite copied')),
        );
      }
    }
  }

  List<Map<String, dynamic>> get _filtered {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _people;
    return _people.where((p) {
      final name = (p['name']?.toString() ?? '').toLowerCase();
      final phone = (p['phone']?.toString() ?? '').toLowerCase();
      return name.contains(q) || phone.contains(q);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Select contact'),
            Text(
              '$_onWamuCount people on Wamu',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Invite a friend',
            onPressed: _loading
                ? null
                : () {
                    final phone = normalizeUgPhone(_phoneController.text);
                    if (phone.length < 12) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Enter a +256 number above, then Invite'),
                        ),
                      );
                      return;
                    }
                    _invite(phone);
                  },
            icon: const Icon(Icons.person_add_alt_1_outlined),
          ),
          IconButton(
            tooltip: 'Refresh',
            onPressed: _dirLoading ? null : _loadDirectory,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _dirLoading
          ? const LoadingView()
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                Text(
                  'Pick someone below, or invite a +256 number that isn’t here yet.',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _searchController,
                  onChanged: (v) => setState(() => _query = v),
                  decoration: const InputDecoration(
                    hintText: 'Search name or phone',
                    prefixIcon: Icon(Icons.search, color: AppTheme.messengerMuted),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _phoneController,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: 'Phone not in list',
                    hintText: '+2567…',
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                ],
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _loading ? null : _lookupAndStart,
                        icon: _loading
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.black,
                                ),
                              )
                            : const Icon(Icons.chat_bubble_outline, size: 18),
                        label: Text(_loading ? 'Working…' : 'Chat / Invite'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Text('On Wamu', style: theme.textTheme.titleMedium),
                    const SizedBox(width: 8),
                    if (_onWamuCount > 0)
                      Text(
                        '$_onWamuCount',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: AppTheme.accentGreen,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                if (_filtered.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Text(
                      'No matches — try another number or invite a friend.',
                      style: TextStyle(color: AppTheme.messengerMuted),
                    ),
                  )
                else
                  ..._filtered.map((p) {
                    final name = p['name']?.toString() ?? 'Wamu user';
                    final phone = p['phone']?.toString() ?? '';
                    final avatar = p['avatar_url']?.toString();
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: ContactAvatar(
                        name: name,
                        phone: phone,
                        avatarUrl: avatar,
                      ),
                      title: Row(
                        children: [
                          Flexible(child: Text(name, overflow: TextOverflow.ellipsis)),
                          const SizedBox(width: 8),
                          const OnWamuBadge(),
                        ],
                      ),
                      subtitle: Text(phone),
                      trailing: const Icon(
                        Icons.chat_bubble_outline,
                        size: 18,
                        color: AppTheme.accentGreen,
                      ),
                      onTap: _loading
                          ? null
                          : () => _start(
                                userId: p['id']?.toString(),
                                phone: phone,
                              ),
                    );
                  }),
                const SizedBox(height: 16),
                Text('Invite to Wamu', style: theme.textTheme.titleMedium),
                const SizedBox(height: 4),
                const Text(
                  'Friends who may not have signed up yet',
                  style: TextStyle(color: AppTheme.messengerMuted, fontSize: 13),
                ),
                const SizedBox(height: 8),
                ..._inviteSuggestions.map(
                  (c) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: ContactAvatar(name: c.$1, phone: c.$2),
                    title: Text(c.$1),
                    subtitle: Text(c.$2),
                    trailing: TextButton.icon(
                      onPressed: _loading ? null : () => _invite(c.$2),
                      icon: const Icon(Icons.sms_outlined, size: 16),
                      label: const Text('Invite'),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

/// Realtime conversation thread — Sprint 2 thread delight.
class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key, required this.conversationId});

  final String conversationId;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  final _recorder = AudioRecorder();
  final _player = AudioPlayer();
  List<ChatMessageModel> _messages = [];
  bool _loading = true;
  bool _uploading = false;
  bool _recording = false;
  bool _voicePreviewReady = false;
  String? _pendingVoicePath;
  String? _pendingVoiceContentType;
  String? _pendingVoiceFilename;
  bool _showEmoji = false;
  String? _error;
  String? _typingLabel;
  String? _playingId;
  String _title = 'Chat';
  bool _canCall = false;
  bool _isGroup = false;
  int _memberCount = 0;
  bool _muted = false;
  bool _peerOnline = false;
  String? _peerLastSeenAt;
  String? _peerUserId;
  String? _peerAvatarUrl;
  List<String> _peerAvatarUrls = const [];
  String? _businessId;
  bool _isMerchantInChat = false;
  bool _ordering = false;
  String _payProvider = 'MTN';
  ChatMessageModel? _replyTo;
  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  Timer? _typingDebounce;
  Timer? _presencePing;
  bool _selecting = false;
  final Set<String> _selectedIds = {};

  static const _reactionEmojis = ['🔥', '😂', '❤️', '👍', '🙌', '😮', '😢', '🙏'];
  static const _composerEmojis = [
    // Smileys
    '😀', '😁', '😂', '🥹', '😅', '😍', '🥰', '😎',
    '🫡', '🤔', '😴', '😭', '😤', '🤯', '😈', '👻',
    // Gestures
    '👍', '👎', '👏', '🙌', '🙏', '🤝', '💪', '✌️',
    '🤞', '👋', '🫶', '❤️', '🔥', '✨', '💯', '⭐',
    // Uganda / everyday
    '🇺🇬', '☕', '🍰', '🍕', '🍻', '⚽', '📱', '🎶',
    '☀️', '🌧️', '🌙', '🎉', '🎂', '🚌', '🏠', '💼',
  ];

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final cache = LocalMessageCache.fromKv(await _kv());
    final cached = await cache.load(widget.conversationId);
    if (cached.isNotEmpty && mounted) {
      setState(() {
        _messages = cached;
        _loading = false;
      });
    }
    try {
      final userId = ref.read(authProvider).user?.id;
      final repo = ref.read(chatRepositoryProvider);
      final convo = await repo.getConversation(widget.conversationId);
      final msgs = await repo.getMessages(
            widget.conversationId,
            currentUserId: userId,
          );
      if (!mounted) return;
      await cache.save(widget.conversationId, msgs);
      var isMerchant = false;
      if (convo.businessId != null) {
        try {
          final mine =
              await ref.read(ownerProductsRepositoryProvider).myBusinesses();
          isMerchant = mine.any((b) => b.id == convo.businessId);
        } catch (_) {
          isMerchant = false;
        }
      }
      if (!mounted) return;
      setState(() {
        _title = convo.displayName;
        _canCall = convo.type == 'DIRECT';
        _isGroup = convo.isGroup;
        _memberCount = convo.memberCount;
        _muted = convo.muted;
        _businessId = convo.businessId;
        _isMerchantInChat = isMerchant;
        final me = ref.read(authProvider).user;
        final canSeeOnline = me?.showOnline ?? true;
        final canSeeLast = me?.showLastSeen ?? true;
        _peerOnline = canSeeOnline && convo.peerOnline;
        _peerLastSeenAt = canSeeLast ? convo.peerLastSeenAt : null;
        _peerUserId = convo.peerUserId;
        _peerAvatarUrl = convo.avatarUrl;
        _peerAvatarUrls = convo.avatarUrls;
        _messages = msgs;
        _loading = false;
        _error = null;
      });
      _connectWs();
      unawaited(_flushOutbox());
      _scrollToEnd();
    } catch (e) {
      if (!mounted) return;
      // Stay on cached thread when offline
      if (cached.isNotEmpty) {
        setState(() {
          _loading = false;
          _error = null;
        });
        unawaited(_flushOutbox());
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Showing offline cache — reconnecting…')),
          );
        }
      } else {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  Future<KvStore> _kv() async {
    try {
      return await ref.read(chatKvStoreProvider.future);
    } catch (_) {
      return SecureKvStore(ref.read(secureStorageProvider));
    }
  }

  Future<MessageOutbox> _outbox() async => MessageOutbox.fromKv(await _kv());

  Future<LocalMessageCache> _cache() async => LocalMessageCache.fromKv(await _kv());

  Future<MediaOutbox> _mediaOutbox() async => MediaOutbox.fromKv(await _kv());

  Future<void> _flushOutbox() async {
    final outbox = await _outbox();
    final pending = await outbox.pendingFor(widget.conversationId);
    if (pending.isEmpty) return;
    final userId = ref.read(authProvider).user?.id;
    // Show queued rows that aren't already in the thread
    final existingIds = _messages.map((m) => m.id).toSet();
    final ghosts = <ChatMessageModel>[
      for (final e in pending)
        if (!existingIds.contains(e.id))
          ChatMessageModel(
            id: e.id,
            content: e.body,
            isMine: true,
            createdAt: e.createdAt,
            status: e.status == OutboxStatus.failed ? 'FAILED' : 'QUEUED',
            messageType: e.messageType,
            mediaUrl: e.mediaUrl,
            replyToMessageId: e.replyToMessageId,
          ),
    ];
    if (ghosts.isNotEmpty && mounted) {
      setState(() => _messages = [..._messages, ...ghosts]);
    }
    for (final entry in pending) {
      if (entry.attempts >= 5) continue;
      await outbox.markSending(entry.id);
      try {
        final saved = await ref.read(chatRepositoryProvider).sendMessage(
              widget.conversationId,
              entry.body,
              currentUserId: userId,
              messageType: entry.messageType,
              mediaUrl: entry.mediaUrl,
              replyToMessageId: entry.replyToMessageId,
              clientMessageId: entry.id,
            );
        await outbox.markSent(entry.id);
        if (!mounted) return;
        setState(() {
          _messages = [
            for (final m in _messages)
              if (m.id == entry.id) saved else m,
          ];
        });
      } catch (e) {
        await outbox.markFailed(entry.id, '$e');
        if (!mounted) return;
        setState(() {
          _messages = [
            for (final m in _messages)
              if (m.id == entry.id) m.copyWith(status: 'FAILED') else m,
          ];
        });
      }
    }
  }

  Future<void> _connectWs() async {
    try {
      final channel =
          await ref.read(chatRepositoryProvider).connectRealtime(widget.conversationId);
      _channel = channel;
      _sub = channel.stream.listen(_onWsEvent, onError: (_) {}, onDone: () {});
      _presencePing?.cancel();
      _presencePing = Timer.periodic(const Duration(seconds: 40), (_) {
        _channel?.sink.add(jsonEncode({'event': 'presence.ping'}));
      });
    } catch (_) {}
  }

  String _presenceSubtitle() {
    if (_typingLabel != null) return _typingLabel!;
    if (_recording) return 'Recording… tap mic to stop';
    if (_voicePreviewReady) return 'Voice note ready · send or delete';
    if (_isGroup) {
      return _memberCount > 0 ? '$_memberCount members' : 'Group';
    }
    if (!_canCall) return '';
    final me = ref.read(authProvider).user;
    final canSeeOnline = me?.showOnline ?? true;
    final canSeeLast = me?.showLastSeen ?? true;
    // Reciprocity: if you hide yours, you don't see theirs either.
    if (canSeeOnline && _peerOnline) return 'online';
    if (!canSeeLast) return '';
    if (_peerLastSeenAt == null || _peerLastSeenAt!.isEmpty) return '';
    try {
      final dt = DateTime.parse(_peerLastSeenAt!).toLocal();
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final day = DateTime(dt.year, dt.month, dt.day);
      final diff = today.difference(day).inDays;
      final hm =
          '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
      if (diff == 0) return 'last seen today at $hm';
      if (diff == 1) return 'last seen yesterday at $hm';
      return 'last seen ${dt.day}/${dt.month} at $hm';
    } catch (_) {
      return '';
    }
  }

  Future<void> _showChatInfo() async {
    final repo = ref.read(chatRepositoryProvider);
    List<Map<String, dynamic>> members = [];
    if (_isGroup) {
      try {
        members = await repo.getMembers(widget.conversationId);
      } catch (_) {}
    }
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade400,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(_title, style: Theme.of(ctx).textTheme.titleLarge),
                const SizedBox(height: 4),
                Text(
                  _isGroup
                      ? '${members.isNotEmpty ? members.length : _memberCount} members'
                      : (_peerUserId != null ? 'Direct chat' : 'Chat'),
                  style: Theme.of(ctx).textTheme.bodyMedium,
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Mute notifications'),
                  value: _muted,
                  activeThumbColor: Colors.black,
                  activeTrackColor: AppTheme.accentGreen,
                  onChanged: (v) async {
                    try {
                      final updated = await repo.updatePrefs(
                        widget.conversationId,
                        muted: v,
                      );
                      if (mounted) setState(() => _muted = updated.muted);
                      if (ctx.mounted) Navigator.pop(ctx);
                    } catch (e) {
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
                      }
                    }
                  },
                ),
                if (!_isGroup && _peerUserId != null) ...[
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.flag_outlined, color: Colors.orange),
                    title: const Text('Report user'),
                    onTap: () async {
                      Navigator.pop(ctx);
                      await _reportPeer();
                    },
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.block, color: Colors.redAccent),
                    title: const Text('Block user', style: TextStyle(color: Colors.redAccent)),
                    onTap: () async {
                      Navigator.pop(ctx);
                      await _blockPeer();
                    },
                  ),
                ],
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
                    title: const Text('Delete chat', style: TextStyle(color: Colors.redAccent)),
                    subtitle: const Text('Removes it from your inbox only. They are not notified.'),
                    onTap: () async {
                      Navigator.pop(ctx);
                      await _hideThisChat();
                    },
                  ),
                if (_isGroup) ...[
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.edit_outlined, color: AppTheme.accentGreen),
                    title: const Text('Rename group'),
                    onTap: () async {
                      Navigator.pop(ctx);
                      await _renameGroup();
                    },
                  ),
                  const Divider(),
                  Text('Members', style: Theme.of(ctx).textTheme.titleSmall),
                  const SizedBox(height: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 220),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: members.length,
                      itemBuilder: (_, i) {
                        final m = members[i];
                        final name = m['name']?.toString() ?? 'Member';
                        final me = m['is_me'] == true;
                        final role = m['member_role']?.toString() ?? 'MEMBER';
                        final uid = m['user_id']?.toString();
                        final iAmAdmin = members.any(
                          (x) => x['is_me'] == true && (x['member_role']?.toString() ?? '') == 'ADMIN',
                        );
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: ContactAvatar(
                            name: name,
                            phone: m['phone']?.toString(),
                            avatarUrl: m['avatar_url']?.toString(),
                          ),
                          title: Text(me ? '$name (you)' : name),
                          subtitle: Text(
                            [
                              if (role == 'ADMIN') 'Admin',
                              m['phone']?.toString() ?? '',
                            ].where((s) => s.isNotEmpty).join(' · '),
                          ),
                          trailing: (!me && iAmAdmin && uid != null)
                              ? IconButton(
                                  tooltip: 'Remove',
                                  icon: const Icon(Icons.person_remove_outlined, color: Colors.redAccent),
                                  onPressed: () async {
                                    Navigator.pop(ctx);
                                    try {
                                      await repo.kickMember(widget.conversationId, uid);
                                      if (mounted) {
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          const SnackBar(content: Text('Member removed')),
                                        );
                                      }
                                    } catch (e) {
                                      if (mounted) {
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          SnackBar(content: Text('$e')),
                                        );
                                      }
                                    }
                                  },
                                )
                              : null,
                        );
                      },
                    ),
                  ),
                  const Divider(),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.logout, color: Colors.redAccent),
                    title: const Text('Leave group', style: TextStyle(color: Colors.redAccent)),
                    onTap: () async {
                      Navigator.pop(ctx);
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (d) => AlertDialog(
                          title: const Text('Leave group?'),
                          content: Text('You will leave “$_title”.'),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
                            TextButton(
                              onPressed: () => Navigator.pop(d, true),
                              child: const Text('Leave', style: TextStyle(color: Colors.redAccent)),
                            ),
                          ],
                        ),
                      );
                      if (ok != true || !mounted) return;
                      try {
                        await repo.leaveConversation(widget.conversationId);
                        if (mounted) context.go('/chats');
                      } catch (e) {
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
                        }
                      }
                    },
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _hideThisChat() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Delete chat?'),
        content: const Text(
          'This chat leaves your inbox only. They keep their copy. No notification is sent.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(d, true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await ref.read(chatRepositoryProvider).hideConversation(widget.conversationId);
      if (mounted) context.go('/chats');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _blockPeer() async {
    final peerId = _peerUserId;
    if (peerId == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Block user?'),
        content: Text('You will no longer be able to message $_title.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(d, true),
            child: const Text('Block', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await ref.read(chatRepositoryProvider).blockUser(peerId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('User blocked')));
        context.go('/chats');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _reportPeer() async {
    final peerId = _peerUserId;
    if (peerId == null) return;
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Report user'),
        content: TextField(
          controller: ctrl,
          maxLines: 3,
          decoration: const InputDecoration(
            labelText: 'What happened?',
            hintText: 'Spam, harassment, scam…',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(d, true), child: const Text('Submit')),
        ],
      ),
    );
    final note = ctrl.text.trim();
    ctrl.dispose();
    if (ok != true || !mounted) return;
    try {
      await ref.read(chatRepositoryProvider).reportUser(
            userId: peerId,
            reason: 'USER_REPORT',
            description: note.isEmpty ? 'Reported from chat' : note,
          );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Report submitted — thank you')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _renameGroup() async {
    final ctrl = TextEditingController(text: _title);
    final next = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename group'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Group name'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (next == null || next.length < 2 || !mounted) return;
    try {
      final updated = await ref.read(chatRepositoryProvider).renameConversation(
            widget.conversationId,
            next,
          );
      if (mounted) setState(() => _title = updated.displayName);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  void _showAttachSheet() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined, color: AppTheme.accentGreen),
              title: const Text('Photo library'),
              subtitle: const Text('Send one or many'),
              onTap: () {
                Navigator.pop(ctx);
                _pickPhotosFromGallery();
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined, color: AppTheme.accentGreen),
              title: const Text('Camera'),
              onTap: () {
                Navigator.pop(ctx);
                _pickPhoto(source: ImageSource.camera);
              },
            ),
            ListTile(
              leading: const Icon(Icons.insert_drive_file_outlined, color: AppTheme.accentGreen),
              title: const Text('Document'),
              subtitle: const Text('PDF up to 5MB'),
              onTap: () {
                Navigator.pop(ctx);
                _pickDocument();
              },
            ),
          ],
        ),
      ),
    );
  }

  void _onWsEvent(dynamic raw) {
    try {
      final data = raw is String ? jsonDecode(raw) as Map<String, dynamic> : raw as Map<String, dynamic>;
      final event = data['event']?.toString();
      final userId = ref.read(authProvider).user?.id;
      if (event == 'typing.started' && data['user_id']?.toString() != userId) {
        setState(() => _typingLabel = 'typing…');
        return;
      }
      if (event == 'typing.stopped') {
        setState(() => _typingLabel = null);
        return;
      }
      if (event == 'presence.updated') {
        final uid = data['user_id']?.toString();
        if (uid == null || uid == userId) return;
        if (_peerUserId != null && uid != _peerUserId) return;
        final me = ref.read(authProvider).user;
        final canSeeOnline = me?.showOnline ?? true;
        final canSeeLast = me?.showLastSeen ?? true;
        setState(() {
          _peerOnline = canSeeOnline && data['online'] == true;
          final ls = data['last_seen_at']?.toString();
          if (canSeeLast && ls != null && ls.isNotEmpty) {
            _peerLastSeenAt = ls;
          } else if (!canSeeLast) {
            _peerLastSeenAt = null;
          }
        });
        return;
      }
      if (event == 'message.status') {
        final ids = (data['ids'] as List?)?.map((e) => e.toString()).toSet() ?? {};
        final status = data['status']?.toString() ?? 'DELIVERED';
        setState(() {
          _messages = [
            for (final m in _messages)
              if (ids.contains(m.id)) m.copyWith(status: status) else m,
          ];
        });
        return;
      }
      if (event == 'message.deleted') {
        final ids = (data['ids'] as List?)?.map((e) => e.toString()).toSet() ?? {};
        if (ids.isEmpty) return;
        setState(() {
          _messages = [for (final m in _messages) if (!ids.contains(m.id)) m];
          _selectedIds.removeWhere(ids.contains);
          if (_selectedIds.isEmpty) _selecting = false;
        });
        return;
      }
      if (event == 'message.new' || event == 'message.reaction') {
        final msg = ChatMessageModel.fromJson(data, currentUserId: userId);
        setState(() {
          final idx = _messages.indexWhere((m) => m.id == msg.id);
          if (idx >= 0) {
            _messages[idx] = msg;
          } else {
            _messages = [
              for (final m in _messages)
                if (!(m.id.startsWith('local-') && m.content == msg.content && m.isMine)) m,
              msg,
            ];
          }
          _typingLabel = null;
        });
        if (!msg.isMine && event == 'message.new' && !msg.id.startsWith('local-')) {
          final receiptsOn =
              ref.read(authProvider).user?.showReadReceipts ?? true;
          if (receiptsOn) {
            unawaited(_ackRead(msg.id));
          } else {
            // Privacy off → gray ✓✓ only; server also caps READ→DELIVERED.
            unawaited(_ackDelivered(msg.id));
          }
        }
        _scrollToEnd();
      }
    } catch (_) {}
  }

  Future<void> _ackDelivered(String messageId) async {
    try {
      await ref.read(chatRepositoryProvider).ackMessage(messageId, 'DELIVERED');
    } catch (_) {}
  }

  Future<void> _ackRead(String messageId) async {
    try {
      await ref.read(chatRepositoryProvider).ackMessage(messageId, 'READ');
    } catch (_) {
      await _ackDelivered(messageId);
    }
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent + 120,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  void _onTyping() {
    _channel?.sink.add(jsonEncode({'event': 'typing.started'}));
    _typingDebounce?.cancel();
    _typingDebounce = Timer(const Duration(milliseconds: 1200), () {
      _channel?.sink.add(jsonEncode({'event': 'typing.stopped'}));
    });
  }

  Future<void> _send() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;
    _messageController.clear();
    setState(() => _showEmoji = false);
    HapticFeedback.lightImpact();
    await _dispatchMessage(body: text);
  }

  Future<void> _dispatchMessage({
    required String body,
    String messageType = 'TEXT',
    String? mediaUrl,
  }) async {
    final userId = ref.read(authProvider).user?.id;
    final reply = _replyTo;
    final outbox = await _outbox();
    final entry = await outbox.enqueue(
      conversationId: widget.conversationId,
      body: body,
      messageType: messageType,
      mediaUrl: mediaUrl,
      replyToMessageId: reply?.id.startsWith('local-') == true ? null : reply?.id,
    );
    final optimistic = ChatMessageModel(
      id: entry.id,
      content: body,
      isMine: true,
      createdAt: entry.createdAt,
      status: 'QUEUED',
      messageType: messageType,
      mediaUrl: mediaUrl,
      replyToMessageId: reply?.id,
      replyTo: reply == null
          ? null
          : MessageReplyPreview(
              id: reply.id,
              body: reply.content,
              senderId: userId ?? '',
              messageType: reply.messageType,
            ),
    );
    setState(() {
      _messages = [..._messages, optimistic];
      _replyTo = null;
    });
    _scrollToEnd();
    await outbox.markSending(entry.id);
    try {
      final saved = await ref.read(chatRepositoryProvider).sendMessage(
            widget.conversationId,
            body,
            currentUserId: userId,
            messageType: messageType,
            mediaUrl: mediaUrl,
            replyToMessageId: entry.replyToMessageId,
            clientMessageId: entry.id,
          );
      await outbox.markSent(entry.id);
      setState(() {
        _messages = [
          for (final m in _messages)
            if (m.id == optimistic.id) saved else m,
        ];
      });
      final cache = await _cache();
      unawaited(cache.upsert(widget.conversationId, saved));
    } catch (e) {
      await outbox.markFailed(entry.id, '$e');
      if (mounted) {
        setState(() {
          _messages = [
            for (final m in _messages)
              if (m.id == optimistic.id) m.copyWith(status: 'FAILED') else m,
          ];
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Queued offline — will retry. ($e)')),
        );
      }
    }
  }

  Future<void> _pickPhoto({required ImageSource source}) async {
    final saver = await ref.read(chatRepositoryProvider).isDataSaverOn();
    Uint8List? bytes;
    var filename = 'photo-${DateTime.now().millisecondsSinceEpoch}.jpg';

    if (source == ImageSource.camera && kIsWeb) {
      if (!mounted) return;
      bytes = await showChatCameraCapture(context);
      filename = 'camera-${DateTime.now().millisecondsSinceEpoch}.jpg';
    } else {
      final picker = ImagePicker();
      XFile? file;
      try {
        file = await picker.pickImage(
          source: source,
          preferredCameraDevice: CameraDevice.rear,
          maxWidth: saver ? 1280 : null,
          imageQuality: saver ? 55 : 92,
        );
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not open ${source == ImageSource.camera ? 'camera' : 'gallery'}: $e')),
          );
        }
        return;
      }
      if (file == null) {
        if (mounted && source == ImageSource.camera) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No photo taken')),
          );
        }
        return;
      }
      bytes = await file.readAsBytes();
      if (file.name.isNotEmpty) filename = file.name;
    }

    if (bytes == null || bytes.isEmpty || !mounted) return;

    // Edit before sharing: crop, zoom, rotate, adjust, caption
    final edited = await showChatImageEditor(context, bytes: bytes);
    if (edited == null || !mounted) return;

    await _uploadAndSendPhoto(
      edited.bytes,
      saver: saver,
      filename: filename.endsWith('.jpg') || filename.endsWith('.jpeg') || filename.endsWith('.png')
          ? filename
          : '$filename.jpg',
      caption: edited.caption,
    );
  }

  Future<void> _pickPhotosFromGallery() async {
    final saver = await ref.read(chatRepositoryProvider).isDataSaverOn();
    final picker = ImagePicker();
    List<XFile> files;
    try {
      files = await picker.pickMultiImage(
        maxWidth: saver ? 1280 : null,
        imageQuality: saver ? 55 : 92,
      );
    } catch (e) {
      // Web / platforms without multi: fall back to single
      await _pickPhoto(source: ImageSource.gallery);
      return;
    }
    if (files.isEmpty) return;
    if (files.length == 1) {
      final bytes = await files.first.readAsBytes();
      if (!mounted || bytes.isEmpty) return;
      final edited = await showChatImageEditor(context, bytes: bytes);
      if (edited == null || !mounted) return;
      var name = files.first.name;
      if (!name.contains('.')) name = '$name.jpg';
      await _uploadAndSendPhoto(
        edited.bytes,
        saver: saver,
        filename: name,
        caption: edited.caption,
      );
      return;
    }

    // Multi: skip per-image editor for speed; send as album
    setState(() => _uploading = true);
    try {
      final batch = files.take(8).toList();
      for (var i = 0; i < batch.length; i++) {
        final file = batch[i];
        var bytes = await file.readAsBytes();
        if (bytes.isEmpty) continue;
        if (saver) bytes = compressForDataSaver(bytes);
        var name = file.name;
        if (!name.contains('.')) {
          name = 'photo-${DateTime.now().millisecondsSinceEpoch}-$i.jpg';
        }
        final url = await ref.read(chatRepositoryProvider).uploadBytes(
              bytes,
              filename: name,
              contentType: 'image/jpeg',
            );
        final isLast = i == batch.length - 1;
        await _dispatchMessage(
          body: batch.length > 1 && isLast
              ? '📷 ${batch.length} photos'
              : (batch.length > 1
                  ? '📷 Photo'
                  : (saver ? '📷 Photo (data saver)' : '📷 Photo')),
          messageType: 'IMAGE',
          mediaUrl: url,
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _pickDocument() async {
    try {
      final picked = await pickPdfDocument();
      if (picked == null) {
        if (mounted && !kIsWeb) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('PDF attach works best on web for now')),
          );
        }
        return;
      }
      final bytes = picked.bytes;
      if (bytes.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not read that file')),
          );
        }
        return;
      }
      if (bytes.length > 5 * 1024 * 1024) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('PDF must be under 5MB')),
          );
        }
        return;
      }
      final name = picked.filename.isNotEmpty ? picked.filename : 'document.pdf';
      setState(() => _uploading = true);
      await _enqueueMediaAndSend(
        bytes: bytes,
        filename: name.toLowerCase().endsWith('.pdf') ? name : '$name.pdf',
        contentType: 'application/pdf',
        messageType: 'DOCUMENT',
        caption: '📄 $name',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _uploadAndSendPhoto(
    Uint8List bytes, {
    required bool saver,
    required String filename,
    String caption = '',
  }) async {
    setState(() => _uploading = true);
    try {
      final payload = saver ? compressForDataSaver(bytes) : bytes;
      final body = caption.isNotEmpty
          ? caption
          : (saver ? '📷 Photo (data saver)' : '📷 Photo');
      await _enqueueMediaAndSend(
        bytes: payload,
        filename: filename,
        contentType: 'image/jpeg',
        messageType: 'IMAGE',
        caption: body,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _enqueueMediaAndSend({
    required Uint8List bytes,
    required String filename,
    required String contentType,
    required String messageType,
    required String caption,
  }) async {
    final media = await _mediaOutbox();
    final entry = await media.enqueue(
      conversationId: widget.conversationId,
      bytes: bytes,
      filename: filename,
      contentType: contentType,
      messageType: messageType,
      caption: caption,
    );
    try {
      await media.markUploading(entry.id);
      final url = await ref.read(chatRepositoryProvider).uploadBytes(
            bytes,
            filename: filename,
            contentType: contentType,
          );
      await media.markDone(entry.id);
      await _dispatchMessage(
        body: caption,
        messageType: messageType,
        mediaUrl: url,
      );
    } catch (e) {
      await media.markFailed(entry.id, '$e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Media queued for retry when online. ($e)')),
        );
      }
    }
  }

  ({AudioEncoder encoder, String ext, String contentType}) _voiceFormat() {
    // Browsers (MediaRecorder) reliably support webm/opus; aacLc often fails on web.
    if (kIsWeb) {
      return (
        encoder: AudioEncoder.opus,
        ext: 'webm',
        contentType: 'audio/webm',
      );
    }
    return (
      encoder: AudioEncoder.aacLc,
      ext: 'm4a',
      contentType: 'audio/mp4',
    );
  }

  Future<void> _toggleRecording() async {
    if (_uploading) return;
    if (_voicePreviewReady) {
      await _sendPendingVoice();
      return;
    }
    if (_recording) {
      await _stopRecording(keep: true);
      return;
    }
    await _startRecording();
  }

  Future<void> _startRecording() async {
    try {
      if (!await _recorder.hasPermission()) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Mic permission needed for voice notes')),
          );
        }
        return;
      }
      final fmt = _voiceFormat();
      final filename = 'voice-${DateTime.now().millisecondsSinceEpoch}.${fmt.ext}';
      final String path;
      if (kIsWeb) {
        path = filename;
      } else {
        final dir = await getTemporaryDirectory();
        path = p.join(dir.path, filename);
      }
      try {
        await _recorder.start(
          RecordConfig(
            encoder: fmt.encoder,
            bitRate: 32000,
            sampleRate: 16000,
            numChannels: 1,
          ),
          path: path,
        );
      } catch (_) {
        // Fallback encoder if the preferred one isn't available on this device.
        final fallbackExt = kIsWeb ? 'webm' : 'wav';
        final fallbackEncoder = kIsWeb ? AudioEncoder.wav : AudioEncoder.wav;
        final fallbackName =
            'voice-${DateTime.now().millisecondsSinceEpoch}.$fallbackExt';
        final fallbackPath = kIsWeb
            ? fallbackName
            : p.join((await getTemporaryDirectory()).path, fallbackName);
        await _recorder.start(
          RecordConfig(
            encoder: fallbackEncoder,
            bitRate: 128000,
            sampleRate: 16000,
            numChannels: 1,
          ),
          path: fallbackPath,
        );
        _pendingVoiceContentType = 'audio/wav';
        _pendingVoiceFilename = fallbackName;
        setState(() => _recording = true);
        HapticFeedback.mediumImpact();
        return;
      }
      _pendingVoiceContentType = fmt.contentType;
      _pendingVoiceFilename = filename;
      setState(() => _recording = true);
      HapticFeedback.mediumImpact();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not record: $e')),
        );
      }
    }
  }

  Future<void> _stopRecording({required bool keep}) async {
    if (!_recording) return;
    String? path;
    try {
      path = await _recorder.stop();
    } catch (_) {
      path = null;
    }
    if (!mounted) return;
    setState(() => _recording = false);
    if (!keep || path == null || path.isEmpty) {
      _clearPendingVoice();
      return;
    }
    setState(() {
      _pendingVoicePath = path;
      _voicePreviewReady = true;
    });
  }

  void _clearPendingVoice() {
    _pendingVoicePath = null;
    _pendingVoiceContentType = null;
    _pendingVoiceFilename = null;
    if (_voicePreviewReady && mounted) {
      setState(() => _voicePreviewReady = false);
    } else {
      _voicePreviewReady = false;
    }
  }

  Future<void> _discardPendingVoice() async {
    if (_recording) {
      await _stopRecording(keep: false);
      return;
    }
    setState(() {
      _voicePreviewReady = false;
      _pendingVoicePath = null;
      _pendingVoiceContentType = null;
      _pendingVoiceFilename = null;
    });
  }

  Future<void> _sendPendingVoice() async {
    final path = _pendingVoicePath;
    if (path == null || path.isEmpty) return;
    final contentType = _pendingVoiceContentType ?? 'audio/webm';
    final filename = _pendingVoiceFilename ??
        'voice-${DateTime.now().millisecondsSinceEpoch}.webm';

    setState(() {
      _uploading = true;
      _voicePreviewReady = false;
    });
    try {
      final bytes = await XFile(path).readAsBytes();
      if (bytes.isEmpty) {
        throw StateError('Recording was empty — try again');
      }
      final url = await ref.read(chatRepositoryProvider).uploadBytes(
            bytes,
            filename: filename,
            contentType: contentType,
          );
      await _dispatchMessage(
        body: '🎤 Voice note',
        messageType: 'VOICE',
        mediaUrl: url,
      );
      _clearPendingVoice();
    } catch (e) {
      if (mounted) {
        setState(() => _voicePreviewReady = true);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _playVoice(ChatMessageModel msg) async {
    final url = resolveMediaUrl(msg.mediaUrl);
    if (url == null || url.isEmpty) return;
    if (_playingId == msg.id) {
      await _player.stop();
      setState(() => _playingId = null);
      return;
    }
    await _player.stop();
    setState(() => _playingId = msg.id);
    try {
      await _player.play(UrlSource(url));
      _player.onPlayerComplete.first.then((_) {
        if (mounted) setState(() => _playingId = null);
      });
    } catch (e) {
      setState(() => _playingId = null);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _startCall({required bool video}) async {
    try {
      final call = await ref.read(callsRepositoryProvider).start(
            conversationId: widget.conversationId,
            callType: video ? 'VIDEO' : 'VOICE',
          );
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ActiveCallScreen(
            callId: call.id,
            isCaller: true,
            peerName: _title,
            video: video,
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _react(ChatMessageModel msg, String emoji) async {
    if (msg.id.startsWith('local-')) return;
    final userId = ref.read(authProvider).user?.id;
    final updated = await ref.read(chatRepositoryProvider).react(
          msg.id,
          emoji,
          currentUserId: userId,
        );
    setState(() {
      _messages = [
        for (final m in _messages)
          if (m.id == msg.id) updated else m,
      ];
    });
  }

  void _setReply(ChatMessageModel msg) {
    setState(() => _replyTo = msg);
    HapticFeedback.selectionClick();
  }

  Future<void> _showMessageActions(ChatMessageModel msg) async {
    if (_selecting) {
      _toggleSelect(msg);
      return;
    }
    HapticFeedback.mediumImpact();
    final action = await showDialog<String>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.35),
      builder: (ctx) {
        final dark = Theme.of(ctx).brightness == Brightness.dark;
        return Dialog(
          backgroundColor: Colors.transparent,
          elevation: 0,
          insetPadding: const EdgeInsets.symmetric(horizontal: 24),
          child: Material(
            color: dark ? AppTheme.messengerElevated : Colors.white,
            elevation: 8,
            borderRadius: BorderRadius.circular(28),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final e in _reactionEmojis)
                          InkWell(
                            onTap: () => Navigator.pop(ctx, 'react:$e'),
                            borderRadius: BorderRadius.circular(20),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
                              child: Text(e, style: const TextStyle(fontSize: 26)),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 4,
                    children: [
                      TextButton.icon(
                        onPressed: () => Navigator.pop(ctx, 'reply'),
                        icon: const Icon(Icons.reply, size: 18, color: AppTheme.accentGreen),
                        label: const Text('Reply'),
                      ),
                      TextButton.icon(
                        onPressed: () => Navigator.pop(ctx, 'forward'),
                        icon: const Icon(Icons.shortcut, size: 18, color: AppTheme.accentGreen),
                        label: const Text('Forward'),
                      ),
                      TextButton.icon(
                        onPressed: () => Navigator.pop(ctx, 'select'),
                        icon: const Icon(Icons.check_circle_outline, size: 18, color: AppTheme.accentGreen),
                        label: const Text('Select'),
                      ),
                      if (!msg.id.startsWith('local-'))
                        TextButton.icon(
                          onPressed: () => Navigator.pop(ctx, 'delete'),
                          icon: const Icon(Icons.delete_outline, size: 18, color: Colors.redAccent),
                          label: const Text('Delete'),
                        ),
                      TextButton.icon(
                        onPressed: () => Navigator.pop(ctx, 'copy'),
                        icon: Icon(
                          Icons.copy_outlined,
                          size: 18,
                          color: dark ? AppTheme.messengerMuted : const Color(0xFF667781),
                        ),
                        label: const Text('Copy'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
    if (action == null) return;
    if (action == 'reply') {
      _setReply(msg);
    } else if (action == 'forward') {
      await _forwardMessages([msg]);
    } else if (action == 'select') {
      _enterSelect(msg);
    } else if (action == 'delete') {
      await _deleteMessages([msg]);
    } else if (action == 'copy') {
      await Clipboard.setData(ClipboardData(text: msg.content));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Copied')),
        );
      }
    } else if (action.startsWith('react:')) {
      await _react(msg, action.substring(6));
    }
  }

  void _enterSelect(ChatMessageModel msg) {
    if (msg.messageType == 'SYSTEM' || msg.id.startsWith('local-')) return;
    HapticFeedback.selectionClick();
    setState(() {
      _selecting = true;
      _selectedIds
        ..clear()
        ..add(msg.id);
    });
  }

  void _toggleSelect(ChatMessageModel msg) {
    if (msg.messageType == 'SYSTEM' || msg.id.startsWith('local-')) return;
    setState(() {
      if (_selectedIds.contains(msg.id)) {
        _selectedIds.remove(msg.id);
      } else {
        _selectedIds.add(msg.id);
      }
      if (_selectedIds.isEmpty) _selecting = false;
    });
  }

  void _exitSelect() {
    setState(() {
      _selecting = false;
      _selectedIds.clear();
    });
  }

  List<ChatMessageModel> get _selectedMessages {
    final byId = {for (final m in _messages) m.id: m};
    return [
      for (final id in _selectedIds)
        if (byId[id] != null) byId[id]!,
    ];
  }

  Future<void> _deleteSelected() async {
    final msgs = _selectedMessages;
    if (msgs.isEmpty) return;
    await _deleteMessages(msgs);
  }

  Future<void> _forwardSelected() async {
    final msgs = _selectedMessages;
    if (msgs.isEmpty) return;
    await _forwardMessages(msgs);
  }

  Future<void> _deleteMessages(List<ChatMessageModel> msgs) async {
    final persisted = [
      for (final m in msgs)
        if (!m.id.startsWith('local-')) m,
    ];
    if (persisted.isEmpty) return;
    final canUnsend = persisted.every((m) => m.isMine);
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppTheme.messengerElevated,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                persisted.length == 1 ? 'Delete message' : 'Delete ${persisted.length} messages',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: const Text('No placeholder. They are not notified.'),
            ),
            ListTile(
              leading: const Icon(Icons.visibility_off_outlined),
              title: const Text('Delete for me'),
              subtitle: const Text('Removes it from this chat only'),
              onTap: () => Navigator.pop(ctx, 'me'),
            ),
            if (canUnsend)
              ListTile(
                leading: const Icon(Icons.delete_forever_outlined, color: Colors.redAccent),
                title: const Text('Delete for everyone', style: TextStyle(color: Colors.redAccent)),
                subtitle: const Text('Silent unsend — disappears on both sides'),
                onTap: () => Navigator.pop(ctx, 'everyone'),
              ),
            ListTile(
              leading: const Icon(Icons.close),
              title: const Text('Cancel'),
              onTap: () => Navigator.pop(ctx),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice != 'me' && choice != 'everyone') return;
    try {
      final deleted = await ref.read(chatRepositoryProvider).deleteMessages(
            widget.conversationId,
            persisted.map((m) => m.id).toList(),
            scope: choice!,
          );
      final gone = deleted.toSet();
      if (!mounted) return;
      setState(() {
        _messages = [for (final m in _messages) if (!gone.contains(m.id)) m];
        _selectedIds.removeWhere(gone.contains);
        if (_selectedIds.isEmpty) _selecting = false;
      });
      if (gone.isEmpty && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Nothing deleted')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _forwardMessage(ChatMessageModel msg) async {
    await _forwardMessages([msg]);
  }

  Future<void> _forwardMessages(List<ChatMessageModel> msgs) async {
    if (msgs.isEmpty) return;
    List<ConversationModel> chats;
    try {
      chats = await ref.read(chatRepositoryProvider).getConversations();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
      return;
    }
    chats = chats.where((c) => !c.archived && c.id != widget.conversationId).toList();
    if (!mounted) return;
    if (chats.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No other chats to forward to')),
      );
      return;
    }
    final target = await showModalBottomSheet<ConversationModel>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.messengerElevated,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(ctx).size.height * 0.55,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  msgs.length == 1 ? 'Forward to…' : 'Forward ${msgs.length} messages to…',
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  itemCount: chats.length,
                  itemBuilder: (_, i) {
                    final c = chats[i];
                    return ListTile(
                      leading: ConversationAvatar(conversation: c, radius: 22),
                      title: Text(c.displayName),
                      subtitle: c.isGroup ? Text('${c.memberCount} members') : null,
                      onTap: () => Navigator.pop(ctx, c),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (target == null) return;
    final userId = ref.read(authProvider).user?.id;
    try {
      for (final msg in msgs) {
        var body = msg.content.trim();
        if (!body.startsWith('↪ ')) body = '↪ $body';
        await ref.read(chatRepositoryProvider).sendMessage(
              target.id,
              body,
              currentUserId: userId,
              messageType: msg.messageType == 'SYSTEM' ? 'TEXT' : msg.messageType,
              mediaUrl: msg.mediaUrl,
            );
      }
      if (mounted) {
        _exitSelect();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Forwarded to ${target.displayName}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  String _timeOf(String? iso) {
    if (iso == null) return '';
    try {
      final dt = DateTime.parse(iso).toLocal();
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return '';
    }
  }

  Widget _statusTicks(ChatMessageModel msg) {
    if (!msg.isMine) return const SizedBox.shrink();
    final s = msg.status.toUpperCase();
    if (s == 'SENDING' || s == 'QUEUED') {
      return const Icon(Icons.schedule, size: 14, color: AppTheme.messengerMuted);
    }
    if (s == 'FAILED') {
      return const Icon(Icons.error_outline, size: 14, color: Colors.orangeAccent);
    }
    if (s == 'READ') {
      return const Icon(Icons.done_all, size: 16, color: Color(0xFF53BDEB));
    }
    if (s == 'DELIVERED') {
      return const Icon(Icons.done_all, size: 16, color: AppTheme.messengerMuted);
    }
    return const Icon(Icons.done, size: 16, color: AppTheme.messengerMuted);
  }

  Widget _quoteBlock(MessageReplyPreview reply, {required bool mine}) {
    final me = ref.read(authProvider).user?.id;
    final senderLabel = () {
      if (reply.senderName != null && reply.senderName!.trim().isNotEmpty) {
        return reply.senderName!.trim();
      }
      if (me != null && reply.senderId == me) return 'You';
      return _title;
    }();
    final label = reply.messageType == 'IMAGE'
        ? '📷 Photo'
        : reply.messageType == 'VOICE'
            ? '🎤 Voice'
            : reply.messageType == 'DOCUMENT'
                ? '📄 Document'
                : reply.body;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: mine ? 0.18 : 0.22),
        borderRadius: BorderRadius.circular(8),
        border: const Border(
          left: BorderSide(color: AppTheme.accentGreen, width: 3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            senderLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: AppTheme.accentGreen,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: mine ? Colors.white.withValues(alpha: 0.85) : AppTheme.messengerMuted,
            ),
          ),
        ],
      ),
    );
  }

  String _mediaAwarePreview(ChatMessageModel msg) {
    final t = msg.messageType.toUpperCase();
    if (t == 'IMAGE') return '📷 Photo';
    if (t == 'VOICE') return '🎤 Voice message';
    if (t == 'ORDER_CARD') {
      final card = _parseOrderCard(msg);
      final pay = (card?['payment_status']?.toString() ?? '').toUpperCase();
      final st = (card?['status']?.toString() ?? '').toUpperCase();
      final del = (card?['delivery_status']?.toString() ?? '').toUpperCase();
      final paid = pay == 'SUCCESS' ||
          st == 'CONFIRMED' ||
          st == 'PAID' ||
          st == 'DELIVERED' ||
          st == 'PROCESSING' ||
          st == 'READY' ||
          st == 'OUT_FOR_DELIVERY';
      if (!paid) return '🧾 Order · Pay with MoMo';
      if (del == 'DELIVERED' || st == 'DELIVERED') return '🧾 Order · Delivered';
      if (del == 'IN_TRANSIT') return '🧾 Order · On the way';
      if (del.isNotEmpty) return '🧾 Order · $del';
      return '🧾 Order · Paid';
    }
    if (t == 'DOCUMENT') {
      final name =
          msg.content.replaceFirst(RegExp(r'^↪\s*'), '').replaceFirst('📄', '').trim();
      return name.isEmpty ? '📄 Document' : '📄 $name';
    }
    final body = msg.content.trim();
    return body.isEmpty ? 'Message' : body;
  }

  Map<String, dynamic>? _parseOrderCard(ChatMessageModel msg) {
    if (msg.messageType != 'ORDER_CARD') return null;
    try {
      final raw = jsonDecode(msg.content);
      if (raw is Map) return Map<String, dynamic>.from(raw);
    } catch (_) {}
    return null;
  }

  Future<void> _payOrderCard(Map<String, dynamic> card) async {
    final orderId = card['order_id']?.toString();
    if (orderId == null || orderId.isEmpty) return;
    setState(() => _ordering = true);
    try {
      final payment = await ref.read(ordersRepositoryProvider).payOrderAndAwait(
            orderId: orderId,
            idempotencyKey: const Uuid().v4(),
            provider: _payProvider,
          );
      if (!mounted) return;
      final status = payment['status']?.toString() ?? 'UNKNOWN';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            status == 'SUCCESS'
                ? '$_payProvider paid — delivery is being assigned'
                : status == 'FAILED'
                    ? '$_payProvider payment failed — try again'
                    : '$_payProvider $status — we will update when MoMo confirms',
          ),
        ),
      );
      await _bootstrap();
      if (mounted && status == 'SUCCESS') {
        context.push('/orders/$orderId');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(apiErrorMessage(e))),
        );
      }
    } finally {
      if (mounted) setState(() => _ordering = false);
    }
  }

  Future<void> _sendOrderCard() async {
    if (_isMerchantInChat) {
      await _composeMerchantReceipt();
      return;
    }
    final businessId = _businessId;
    if (businessId == null) return;
    setState(() => _ordering = true);
    try {
      final products = (await ref.read(catalogRepositoryProvider).getProducts(
            businessId: businessId,
            pageSize: 100,
          ))
          .items;
      if (!mounted) return;
      if (products.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No products to order yet')),
        );
        return;
      }
      final picked = await showModalBottomSheet<ProductModel>(
        context: context,
        builder: (ctx) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              const ListTile(
                title: Text(
                  'Send order card',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: Text('Creates order + Pay with MoMo card in chat'),
              ),
              ...products.map(
                (p) => ListTile(
                  title: Text(p.name),
                  subtitle: Text(formatUgx(p.price)),
                  onTap: () => Navigator.pop(ctx, p),
                ),
              ),
            ],
          ),
        ),
      );
      if (picked == null || !mounted) return;
      final addressCtrl = TextEditingController();
      final address = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Delivery address'),
          content: TextField(
            controller: addressCtrl,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: 'e.g. Ntinda Shopping Centre, Kampala',
            ),
            textCapitalization: TextCapitalization.sentences,
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, addressCtrl.text.trim()),
              child: const Text('Continue'),
            ),
          ],
        ),
      );
      if (address == null || address.isEmpty || !mounted) return;
      await ref.read(ordersRepositoryProvider).createOrder({
        'business_id': businessId,
        'conversation_id': widget.conversationId,
        'fulfillment': 'DELIVERY',
        'delivery_address': address,
        'customer_note': 'Ordered from Wamu chat',
        'items': [
          {'product_id': picked.id, 'quantity': 1},
        ],
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Order card sent — Pay with MoMo')),
      );
      await _bootstrap();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _ordering = false);
    }
  }

  Future<void> _composeMerchantReceipt({String? reviseOrderId}) async {
    final businessId = _businessId;
    if (businessId == null) return;
    setState(() => _ordering = true);
    try {
      final products = (await ref.read(catalogRepositoryProvider).getProducts(
            businessId: businessId,
            pageSize: 100,
          ))
          .items;
      if (!mounted) return;
      if (products.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Add products in My business first')),
        );
        return;
      }
      final draft = await showReceiptComposer(
        context: context,
        products: products,
        title: reviseOrderId == null ? 'Create payment receipt' : 'Edit receipt',
        submitLabel: reviseOrderId == null ? 'Send to buyer' : 'Update receipt',
      );
      if (draft == null || !mounted) return;
      if (reviseOrderId != null) {
        await ref.read(ordersRepositoryProvider).reviseReceipt(reviseOrderId, draft);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Receipt updated — buyer can pay the new total')),
        );
      } else {
        await ref.read(ordersRepositoryProvider).createOrder({
          'business_id': businessId,
          'conversation_id': widget.conversationId,
          ...draft,
        });
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Receipt sent — buyer can Pay with MoMo')),
        );
      }
      await _bootstrap();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _ordering = false);
    }
  }

  Widget _orderCardBubble(ChatMessageModel msg) {
    final card = _parseOrderCard(msg);
    if (card == null) {
      return const Text('Order card', style: TextStyle(fontWeight: FontWeight.w600));
    }
    final total = double.tryParse('${card['total']}') ?? 0;
    final status = (card['status']?.toString() ?? 'PENDING').toUpperCase();
    final payStatus = (card['payment_status']?.toString() ?? '').toUpperCase();
    final paid = payStatus == 'SUCCESS' ||
        status == 'CONFIRMED' ||
        status == 'PAID' ||
        status == 'DELIVERED' ||
        status == 'PROCESSING' ||
        status == 'READY' ||
        status == 'OUT_FOR_DELIVERY';
    final items = (card['items'] is List) ? card['items'] as List : const [];
    final itemLine = items.isEmpty
        ? 'Order'
        : items
            .map((e) {
              if (e is Map) return '${e['name']} × ${e['qty'] ?? 1}';
              return '$e';
            })
            .join(', ');
    final meId = ref.read(authProvider).user?.id;
    final customerId = card['customer_id']?.toString();
    final iAmBuyer = customerId == null || customerId == meId;
    final canPay = !paid && iAmBuyer && !_isMerchantInChat;
    final canEdit = !paid && _isMerchantInChat;
    final orderId = card['order_id']?.toString();
    return Container(
      width: MediaQuery.of(context).size.width * 0.78,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark
            ? const Color(0xFF1A2E24)
            : const Color(0xFFF0FFF4),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.accentGreen.withValues(alpha: 0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  card['business_name']?.toString() ?? 'Order',
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                ),
              ),
              if (card['merchant_receipt'] == true)
                const Text(
                  'Receipt',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(itemLine, style: TextStyle(color: AppTheme.messengerMuted, height: 1.3)),
          const SizedBox(height: 8),
          Text(
            formatUgx(total),
            style: const TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 18,
              color: AppTheme.accentGreen,
            ),
          ),
          if (card['delivery_address'] != null) ...[
            const SizedBox(height: 4),
            Text(
              'Deliver to ${card['delivery_address']}',
              style: TextStyle(fontSize: 12, color: AppTheme.messengerMuted),
            ),
          ],
          const SizedBox(height: 12),
          if (canPay) ...[
            MomoProviderPicker(
              value: _payProvider,
              compact: true,
              enabled: !_ordering,
              onChanged: (v) => setState(() => _payProvider = v),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _ordering ? null : () => _payOrderCard(card),
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.accentGreen,
                  foregroundColor: Colors.black,
                ),
                child: Text(
                  _ordering
                      ? 'Paying…'
                      : (card['pay_cta']?.toString() ?? 'Pay with $_payProvider'),
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
            ),
          ] else if (canEdit && orderId != null) ...[
            Text(
              'Waiting for buyer to pay',
              style: TextStyle(fontSize: 12, color: AppTheme.messengerMuted),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed:
                    _ordering ? null : () => _composeMerchantReceipt(reviseOrderId: orderId),
                icon: const Icon(Icons.edit_outlined, size: 18),
                label: const Text('Edit receipt'),
              ),
            ),
          ] else if (paid) ...[
            Text(
              _paidStatusLine(card, status),
              style: const TextStyle(
                color: AppTheme.accentGreen,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _paidStatusLine(Map<String, dynamic> card, String orderStatus) {
    final del = (card['delivery_status']?.toString() ?? '').toUpperCase();
    const delLabels = {
      'ACCEPTED': 'Rider assigned',
      'GOING_TO_PICKUP': 'Rider going to shop',
      'AT_PICKUP': 'Rider at shop',
      'PICKED_UP': 'Picked up',
      'IN_TRANSIT': 'On the way to you',
      'DELIVERED': 'Delivered',
      'CANCELLED': 'Delivery cancelled',
    };
    if (del.isNotEmpty && delLabels.containsKey(del)) {
      return 'Paid · ${delLabels[del]}';
    }
    const orderLabels = {
      'CONFIRMED': 'Paid · shop confirmed',
      'PROCESSING': 'Paid · preparing',
      'READY': 'Paid · ready',
      'OUT_FOR_DELIVERY': 'Paid · out for delivery',
      'DELIVERED': 'Paid · delivered',
      'CANCELLED': 'Paid · cancelled',
    };
    return orderLabels[orderStatus] ?? 'Paid · tracking';
  }

  Widget _bubbleBody(ChatMessageModel msg, ThemeData theme) {
    if (msg.messageType == 'ORDER_CARD') {
      return _orderCardBubble(msg);
    }
    final dark = theme.brightness == Brightness.dark;
    final onMine = msg.isMine
        ? (dark ? Colors.white : const Color(0xFF111B21))
        : (dark ? AppTheme.messengerText : const Color(0xFF111B21));
    final kids = <Widget>[];
    if (msg.isForwarded) {
      kids.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(
            'Forwarded',
            style: TextStyle(
              fontSize: 11,
              fontStyle: FontStyle.italic,
              color: onMine.withValues(alpha: 0.7),
            ),
          ),
        ),
      );
    }
    if (msg.isImage && msg.mediaUrl != null) {
      final caption = msg.content.trim().replaceFirst(RegExp(r'^↪\s*'), '');
      final showCaption = caption.isNotEmpty &&
          !caption.startsWith('📷') &&
          caption.toLowerCase() != 'photo';
      kids.addAll([
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: ChatMediaImage(
            imageUrl: msg.mediaUrl,
            width: 240,
            height: 200,
          ),
        ),
        if (showCaption) ...[
          const SizedBox(height: 6),
          Text(caption, style: TextStyle(color: onMine)),
        ],
      ]);
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: kids);
    }
    if (msg.isDocument && msg.mediaUrl != null) {
      final name = msg.content.replaceFirst(RegExp(r'^↪\s*'), '').replaceFirst('📄', '').trim();
      kids.add(
        InkWell(
          onTap: () async {
            final resolved = resolveMediaUrl(msg.mediaUrl);
            final uri = Uri.tryParse(resolved ?? '');
            if (uri == null) return;
            final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
            if (!ok && mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Could not open document')),
              );
            }
          },
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: Colors.redAccent.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.picture_as_pdf, color: Colors.redAccent),
              ),
              const SizedBox(width: 10),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 160),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name.isEmpty ? 'Document.pdf' : name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: onMine, fontWeight: FontWeight.w600),
                    ),
                    Text(
                      'PDF · tap to open',
                      style: TextStyle(fontSize: 11, color: onMine.withValues(alpha: 0.65)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: kids);
    }
    if (msg.isVoice && msg.mediaUrl != null) {
      kids.add(
        ChatVoiceNote(
          playing: _playingId == msg.id,
          foreground: onMine,
          onPlay: () => _playVoice(msg),
        ),
      );
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: kids);
    }
    if (msg.messageType == 'SYSTEM') {
      return Text(
        msg.content,
        style: TextStyle(
          color: AppTheme.messengerMuted,
          fontStyle: FontStyle.italic,
          fontSize: 13,
        ),
      );
    }
    final text = msg.content.replaceFirst(RegExp(r'^↪\s*'), '');
    kids.add(Text(text, style: TextStyle(color: onMine, height: 1.35)));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: kids);
  }

  @override
  void dispose() {
    _typingDebounce?.cancel();
    _presencePing?.cancel();
    _sub?.cancel();
    _channel?.sink.close();
    _recorder.dispose();
    _player.dispose();
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final hasText = _messageController.text.trim().isNotEmpty;

    return Scaffold(
      backgroundColor: dark ? const Color(0xFF0E1A14) : const Color(0xFFECE5DD),
      appBar: AppBar(
        backgroundColor: dark ? AppTheme.messengerSurface : Colors.white,
        leading: _selecting
            ? IconButton(
                tooltip: 'Cancel',
                onPressed: _exitSelect,
                icon: const Icon(Icons.close),
              )
            : null,
        title: _selecting
            ? Text('${_selectedIds.length} selected')
            : InkWell(
                onTap: _showChatInfo,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
                  child: Row(
                    children: [
                      ConversationAvatar(
                        conversation: ConversationModel(
                          id: widget.conversationId,
                          type: _isGroup ? 'GROUP' : 'DIRECT',
                          businessId: _businessId,
                          participantName: _title,
                          avatarUrl: _peerAvatarUrl,
                          avatarUrls: _peerAvatarUrls,
                        ),
                        radius: 18,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                            ),
                            Builder(
                              builder: (context) {
                                final sub = _presenceSubtitle();
                                if (sub.isEmpty) return const SizedBox.shrink();
                                final isOnline = sub == 'online' || sub == 'typing…';
                                return Text(
                                  sub,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w400,
                                    color: isOnline
                                        ? AppTheme.accentGreen
                                        : AppTheme.messengerMuted,
                                  ),
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
        actions: _selecting
            ? [
                IconButton(
                  tooltip: 'Forward',
                  onPressed: _selectedIds.isEmpty ? null : _forwardSelected,
                  icon: const Icon(Icons.shortcut),
                ),
                IconButton(
                  tooltip: 'Delete',
                  onPressed: _selectedIds.isEmpty ? null : _deleteSelected,
                  icon: const Icon(Icons.delete_outline),
                ),
              ]
            : [
                if (_businessId != null)
                  IconButton(
                    tooltip: _isMerchantInChat ? 'Create payment receipt' : 'Send order card',
                    onPressed: _ordering ? null : _sendOrderCard,
                    icon: Icon(
                      _isMerchantInChat ? Icons.request_quote_outlined : Icons.receipt_long_outlined,
                    ),
                  ),
                IconButton(
                  tooltip: 'Chat info',
                  onPressed: _showChatInfo,
                  icon: const Icon(Icons.info_outline),
                ),
                if (_canCall) ...[
                  IconButton(
                    tooltip: 'Voice call',
                    onPressed: () => _startCall(video: false),
                    icon: const Icon(Icons.call),
                  ),
                  IconButton(
                    tooltip: 'Video call',
                    onPressed: () => _startCall(video: true),
                    icon: const Icon(Icons.videocam),
                  ),
                ],
              ],
      ),
      body: _loading
          ? const LoadingView()
          : _error != null
              ? ErrorView(message: _error!, onRetry: _bootstrap)
              : ChatWallpaper(
                  child: Column(
                    children: [
                      if (_uploading)
                        const LinearProgressIndicator(
                          minHeight: 2,
                          color: AppTheme.accentGreen,
                        ),
                      Expanded(
                        child: Builder(
                          builder: (context) {
                            final runs = groupMessageRuns(_messages);
                            return ListView.builder(
                              controller: _scrollController,
                              padding: const EdgeInsets.fromLTRB(10, 12, 10, 12),
                              itemCount: runs.length,
                              itemBuilder: (context, index) {
                                final run = runs[index];
                                final msg = run.first;
                                if (msg.messageType == 'SYSTEM') {
                                  return Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 8),
                                    child: Center(
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 12,
                                          vertical: 6,
                                        ),
                                        decoration: BoxDecoration(
                                          color: AppTheme.messengerElevated.withValues(alpha: 0.85),
                                          borderRadius: BorderRadius.circular(8),
                                        ),
                                        child: _bubbleBody(msg, theme),
                                      ),
                                    ),
                                  );
                                }
                                if (msg.messageType == 'ORDER_CARD') {
                                  return Align(
                                    alignment: Alignment.centerLeft,
                                    child: Padding(
                                      padding: const EdgeInsets.only(bottom: 8),
                                      child: _orderCardBubble(msg),
                                    ),
                                  );
                                }
                                final album = run.length > 1 && run.every((m) => m.isImage);
                                final last = run.last;
                                final selected = _selectedIds.contains(last.id);
                                return Align(
                                  alignment: msg.isMine
                                      ? Alignment.centerRight
                                      : Alignment.centerLeft,
                                  child: GestureDetector(
                                    onTap: _selecting ? () => _toggleSelect(last) : null,
                                    onLongPress: () {
                                      if (_selecting) {
                                        _toggleSelect(last);
                                      } else {
                                        _showMessageActions(last);
                                      }
                                    },
                                    onHorizontalDragEnd: _selecting
                                        ? null
                                        : (d) {
                                            if ((d.primaryVelocity ?? 0) > 280) {
                                              _setReply(last);
                                            }
                                          },
                                    child: Container(
                                      margin: const EdgeInsets.only(bottom: 6),
                                      padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
                                      constraints: BoxConstraints(
                                        maxWidth: MediaQuery.of(context).size.width * 0.78,
                                      ),
                                      decoration: BoxDecoration(
                                        color: msg.isMine
                                            ? (dark
                                                ? const Color(0xFF005C4B)
                                                : const Color(0xFFD9FDD3))
                                            : (dark
                                                ? AppTheme.messengerElevated
                                                : Colors.white),
                                        borderRadius: BorderRadius.only(
                                          topLeft: const Radius.circular(12),
                                          topRight: const Radius.circular(12),
                                          bottomLeft: Radius.circular(msg.isMine ? 12 : 4),
                                          bottomRight: Radius.circular(msg.isMine ? 4 : 12),
                                        ),
                                        border: selected
                                            ? Border.all(color: AppTheme.accentGreen, width: 2)
                                            : null,
                                      ),
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.end,
                                        children: [
                                          if (_selecting)
                                            Align(
                                              alignment: Alignment.centerLeft,
                                              child: Padding(
                                                padding: const EdgeInsets.only(bottom: 4),
                                                child: Icon(
                                                  selected
                                                      ? Icons.check_circle
                                                      : Icons.radio_button_unchecked,
                                                  size: 20,
                                                  color: selected
                                                      ? AppTheme.accentGreen
                                                      : AppTheme.messengerMuted,
                                                ),
                                              ),
                                            ),
                                          if (msg.replyTo != null)
                                            _quoteBlock(msg.replyTo!, mine: msg.isMine),
                                          Align(
                                            alignment: Alignment.centerLeft,
                                            child: album
                                                ? ChatMediaGrid(
                                                    messages: run,
                                                    onLongPress: (m) {
                                                      if (_selecting) {
                                                        _toggleSelect(m);
                                                      } else {
                                                        _showMessageActions(m);
                                                      }
                                                    },
                                                  )
                                                : _bubbleBody(msg, theme),
                                          ),
                                          if (last.reactions.isNotEmpty) ...[
                                            const SizedBox(height: 4),
                                            Align(
                                              alignment: Alignment.centerLeft,
                                              child: Wrap(
                                                spacing: 4,
                                                children: last.reactions.entries
                                                    .map(
                                                      (e) => Container(
                                                        padding: const EdgeInsets.symmetric(
                                                          horizontal: 6,
                                                          vertical: 2,
                                                        ),
                                                        decoration: BoxDecoration(
                                                          color: Colors.black.withValues(alpha: 0.25),
                                                          borderRadius: BorderRadius.circular(10),
                                                        ),
                                                        child: Text(
                                                          '${e.key} ${e.value}',
                                                          style: const TextStyle(fontSize: 12),
                                                        ),
                                                      ),
                                                    )
                                                    .toList(),
                                              ),
                                            ),
                                          ],
                                          const SizedBox(height: 2),
                                          Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Text(
                                                _timeOf(last.createdAt),
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  color: msg.isMine
                                                      ? Colors.white.withValues(alpha: 0.65)
                                                      : AppTheme.messengerMuted,
                                                ),
                                              ),
                                              if (msg.isMine) ...[
                                                const SizedBox(width: 4),
                                                _statusTicks(last),
                                              ],
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              },
                            );
                          },
                        ),
                      ),
                      if (_replyTo != null)
                        Container(
                          color: AppTheme.messengerSurface,
                          padding: const EdgeInsets.fromLTRB(12, 8, 4, 4),
                          child: Row(
                            children: [
                              Container(
                                width: 3,
                                height: 36,
                                color: AppTheme.accentGreen,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'Replying',
                                      style: TextStyle(
                                        color: AppTheme.accentGreen,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    Text(
                                      _mediaAwarePreview(_replyTo!),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: AppTheme.messengerMuted,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                onPressed: () => setState(() => _replyTo = null),
                                icon: const Icon(Icons.close, size: 18),
                              ),
                            ],
                          ),
                        ),
                      if (_showEmoji)
                        Container(
                          height: 220,
                          color: AppTheme.messengerSurface,
                          padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
                          child: GridView.count(
                            crossAxisCount: 8,
                            children: _composerEmojis
                                .map(
                                  (e) => InkWell(
                                    onTap: () {
                                      final t = _messageController.text;
                                      final sel = _messageController.selection;
                                      final start = sel.start >= 0 ? sel.start : t.length;
                                      final end = sel.end >= 0 ? sel.end : t.length;
                                      final next = t.replaceRange(start, end, e);
                                      _messageController.value = TextEditingValue(
                                        text: next,
                                        selection: TextSelection.collapsed(
                                          offset: start + e.length,
                                        ),
                                      );
                                      setState(() {});
                                    },
                                    child: Center(
                                      child: Text(e, style: const TextStyle(fontSize: 24)),
                                    ),
                                  ),
                                )
                                .toList(),
                          ),
                        ),
                      SafeArea(
                        top: false,
                        child: Container(
                          color: AppTheme.messengerSurface,
                          padding: const EdgeInsets.fromLTRB(6, 6, 6, 8),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Expanded(
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: AppTheme.messengerInput,
                                    borderRadius: BorderRadius.circular(24),
                                  ),
                                  child: Row(
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      IconButton(
                                        tooltip: 'Emoji',
                                        onPressed: () =>
                                            setState(() => _showEmoji = !_showEmoji),
                                        icon: Icon(
                                          _showEmoji
                                              ? Icons.keyboard_alt_outlined
                                              : Icons.emoji_emotions_outlined,
                                          color: AppTheme.messengerMuted,
                                          size: 22,
                                        ),
                                      ),
                                      Expanded(
                                        child: TextField(
                                          controller: _messageController,
                                          enabled: !_recording,
                                          minLines: 1,
                                          maxLines: 8,
                                          keyboardType: TextInputType.multiline,
                                          textInputAction: TextInputAction.newline,
                                          style: const TextStyle(color: AppTheme.messengerText),
                                          decoration: InputDecoration(
                                            hintText:
                                                _recording
                                                    ? 'Recording… tap stop'
                                                    : _voicePreviewReady
                                                        ? 'Voice note ready'
                                                        : 'Message',
                                            border: InputBorder.none,
                                            enabledBorder: InputBorder.none,
                                            focusedBorder: InputBorder.none,
                                            filled: false,
                                            contentPadding: const EdgeInsets.fromLTRB(
                                              0,
                                              10,
                                              4,
                                              10,
                                            ),
                                          ),
                                          onChanged: (_) {
                                            setState(() {});
                                            _onTyping();
                                          },
                                          onTap: () {
                                            if (_showEmoji) {
                                              setState(() => _showEmoji = false);
                                            }
                                          },
                                        ),
                                      ),
                                      IconButton(
                                        tooltip: 'Attach',
                                        onPressed: _uploading ? null : _showAttachSheet,
                                        icon: const Icon(
                                          Icons.attach_file,
                                          color: AppTheme.messengerMuted,
                                          size: 22,
                                        ),
                                      ),
                                      IconButton(
                                        tooltip: 'Camera',
                                        onPressed: _uploading
                                            ? null
                                            : () => _pickPhoto(source: ImageSource.camera),
                                        icon: const Icon(
                                          Icons.photo_camera_outlined,
                                          color: AppTheme.messengerMuted,
                                          size: 22,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(width: 4),
                              if (_voicePreviewReady) ...[
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 2),
                                  child: Material(
                                    color: Colors.redAccent,
                                    shape: const CircleBorder(),
                                    child: IconButton(
                                      tooltip: 'Delete recording',
                                      onPressed: _uploading ? null : _discardPendingVoice,
                                      icon: const Icon(Icons.delete_outline, color: Colors.white, size: 20),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 2),
                                  child: Material(
                                    color: AppTheme.accentGreen,
                                    shape: const CircleBorder(),
                                    child: IconButton(
                                      tooltip: 'Send voice note',
                                      onPressed: _uploading ? null : _sendPendingVoice,
                                      icon: _uploading
                                          ? const SizedBox(
                                              width: 18,
                                              height: 18,
                                              child: CircularProgressIndicator(strokeWidth: 2),
                                            )
                                          : const Icon(Icons.send, color: Colors.black, size: 20),
                                    ),
                                  ),
                                ),
                              ] else if (hasText && !_recording)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 2),
                                  child: Material(
                                    color: AppTheme.accentGreen,
                                    shape: const CircleBorder(),
                                    child: IconButton(
                                      onPressed: _send,
                                      icon: const Icon(Icons.send, color: Colors.black, size: 20),
                                    ),
                                  ),
                                )
                              else
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 2),
                                  child: Material(
                                    color: _recording
                                        ? Colors.redAccent
                                        : AppTheme.accentGreen,
                                    shape: const CircleBorder(),
                                    child: IconButton(
                                      tooltip: _recording
                                          ? 'Tap to stop'
                                          : 'Tap to record voice note',
                                      onPressed: _uploading ? null : _toggleRecording,
                                      icon: Icon(
                                        _recording ? Icons.stop : Icons.mic,
                                        color: _recording ? Colors.white : Colors.black,
                                        size: 22,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
    );
  }
}

