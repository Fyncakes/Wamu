import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/media_url.dart';
import '../../core/network/api_client.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/widgets/error_view.dart';
import '../../shared/widgets/loading_view.dart';
import '../auth/auth_provider.dart';
import 'chat_repository.dart';

/// Updates = Status (horizontal) + Channels (Sprint 3).
class StatusScreen extends ConsumerStatefulWidget {
  const StatusScreen({super.key});

  @override
  ConsumerState<StatusScreen> createState() => _StatusScreenState();
}

class _StatusRing {
  _StatusRing({
    required this.userId,
    required this.name,
    required this.isMine,
    required this.items,
  });

  final String userId;
  final String name;
  final bool isMine;
  final List<Map<String, dynamic>> items;
}

class _StatusScreenState extends ConsumerState<StatusScreen> {
  late Future<_UpdatesData> _future;
  String? _followingId;
  bool _searching = false;
  String _query = '';
  final _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _load() {
    _future = _fetch();
  }

  Future<_UpdatesData> _fetch() async {
    final client = ref.read(apiClientProvider);
    final repo = ref.read(chatRepositoryProvider);
    final statusRes = await client.get('/status');
    final channelRes = await client.get('/communities/channels');
    final convos = await repo.getConversations();

    final statuses = statusRes.data is List
        ? (statusRes.data as List).cast<Map<String, dynamic>>()
        : <Map<String, dynamic>>[];
    final channels = (channelRes.data is Map && channelRes.data['items'] is List)
        ? (channelRes.data['items'] as List).cast<Map<String, dynamic>>()
        : <Map<String, dynamic>>[];

    final joined = {
      for (final c in convos)
        if (c.communitySlug != null && c.communitySlug!.isNotEmpty) c.communitySlug!,
    };
    final convoBySlug = {
      for (final c in convos)
        if (c.communitySlug != null) c.communitySlug!: c.id,
    };

    return _UpdatesData(
      rings: _groupStatuses(statuses),
      channels: channels,
      joinedSlugs: joined,
      convoBySlug: convoBySlug,
    );
  }

  List<_StatusRing> _groupStatuses(List<Map<String, dynamic>> items) {
    final order = <String>[];
    final map = <String, _StatusRing>{};
    for (final s in items) {
      final uid = s['user_id']?.toString() ?? '';
      if (uid.isEmpty) continue;
      if (!map.containsKey(uid)) {
        order.add(uid);
        map[uid] = _StatusRing(
          userId: uid,
          name: s['user_name']?.toString() ?? 'Wamu',
          isMine: s['is_mine'] == true,
          items: [s],
        );
      } else {
        map[uid]!.items.add(s);
      }
    }
    final rings = order.map((id) => map[id]!).toList();
    rings.sort((a, b) {
      if (a.isMine && !b.isMine) return -1;
      if (!a.isMine && b.isMine) return 1;
      return 0;
    });
    return rings;
  }

  Future<void> _composeText() async {
    final controller = TextEditingController();
    var color = '#0B6E4F';
    final colors = {
      '#0B6E4F': const Color(0xFF0B6E4F),
      '#C45C26': const Color(0xFFC45C26),
      '#1B4F72': const Color(0xFF1B4F72),
      '#6C3483': const Color(0xFF6C3483),
      '#117A65': const Color(0xFF117A65),
    };
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.messengerElevated,
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
          ),
          child: StatefulBuilder(
            builder: (ctx, setLocal) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Text status', style: Theme.of(ctx).textTheme.titleLarge),
                  const SizedBox(height: 8),
                  Text(
                    'Disappears in 24 hours · keep it light on data',
                    style: Theme.of(ctx).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: controller,
                    maxLength: 140,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      hintText: 'What’s the vibe in Kampala today?',
                    ),
                  ),
                  Wrap(
                    spacing: 8,
                    children: colors.entries
                        .map(
                          (e) => GestureDetector(
                            onTap: () => setLocal(() => color = e.key),
                            child: CircleAvatar(
                              backgroundColor: e.value,
                              radius: 16,
                              child: color == e.key
                                  ? const Icon(Icons.check, color: Colors.white, size: 16)
                                  : null,
                            ),
                          ),
                        )
                        .toList(),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Post status'),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
    final text = controller.text.trim();
    controller.dispose();
    if (ok != true || text.isEmpty) return;
    await ref.read(apiClientProvider).post('/status', data: {
      'body': text,
      'media_type': 'TEXT',
      'background_color': color,
    });
    if (mounted) setState(_load);
  }

  Future<void> _composePhoto({ImageSource source = ImageSource.camera}) async {
    final saver = await ref.read(chatRepositoryProvider).isDataSaverOn();
    final picker = ImagePicker();
    final file = await picker.pickImage(
      source: source,
      maxWidth: saver ? 1080 : 1600,
      imageQuality: saver ? 65 : 82,
    );
    if (file == null) return;
    try {
      final bytes = await file.readAsBytes();
      final url = await ref.read(chatRepositoryProvider).uploadBytes(
            bytes,
            filename: file.name.isNotEmpty ? file.name : 'status.jpg',
            contentType: 'image/jpeg',
          );
      await ref.read(apiClientProvider).post('/status', data: {
        'body': saver ? '📷 Status (data saver)' : '📷 Status',
        'media_type': 'IMAGE',
        'media_url': url,
        'background_color': '#0B6E4F',
      });
      if (mounted) setState(_load);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _pickStatusMedia() async {
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
              leading: const Icon(Icons.photo_camera, color: AppTheme.accentGreen),
              title: const Text('Camera'),
              onTap: () => Navigator.pop(ctx, 'camera'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined, color: AppTheme.accentGreen),
              title: const Text('Gallery'),
              onTap: () => Navigator.pop(ctx, 'gallery'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == 'camera') {
      await _composePhoto(source: ImageSource.camera);
    } else if (choice == 'gallery') {
      await _composePhoto(source: ImageSource.gallery);
    }
  }

  void _openRing(_StatusRing ring) {
    var index = 0;
    showDialog(
      context: context,
      barrierColor: Colors.black87,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            final s = ring.items[index];
            final hex = (s['background_color']?.toString() ?? '#0B6E4F').replaceAll('#', '');
            final bg = Color(int.parse('FF$hex', radix: 16));
            final isImage = (s['media_type']?.toString() ?? '').toUpperCase() == 'IMAGE';
            return GestureDetector(
              onTap: () {
                if (index < ring.items.length - 1) {
                  setLocal(() => index++);
                } else {
                  Navigator.pop(ctx);
                }
              },
              child: Dialog(
                insetPadding: const EdgeInsets.all(0),
                backgroundColor: bg,
                child: SafeArea(
                  child: SizedBox(
                    width: double.infinity,
                    height: MediaQuery.of(ctx).size.height * 0.85,
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  ring.name,
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              Text(
                                '${index + 1}/${ring.items.length}',
                                style: const TextStyle(color: Colors.white54, fontSize: 12),
                              ),
                              IconButton(
                                onPressed: () => Navigator.pop(ctx),
                                icon: const Icon(Icons.close, color: Colors.white70),
                              ),
                            ],
                          ),
                          const Spacer(),
                          if (isImage && (s['media_url']?.toString().isNotEmpty ?? false))
                            Expanded(
                              child: Image.network(
                                resolveMediaUrl(s['media_url'].toString()) ??
                                    s['media_url'].toString(),
                                fit: BoxFit.contain,
                                errorBuilder: (context, error, stackTrace) => const Icon(
                                  Icons.broken_image,
                                  color: Colors.white54,
                                  size: 48,
                                ),
                              ),
                            )
                          else
                            Text(
                              s['body']?.toString() ?? '',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 26,
                                fontWeight: FontWeight.w600,
                                height: 1.3,
                              ),
                            ),
                          const Spacer(),
                          const Text(
                            'Tap to next · 24h',
                            style: TextStyle(color: Colors.white54, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _followChannel(Map<String, dynamic> channel, _UpdatesData data) async {
    final id = channel['id']?.toString();
    if (id == null) return;
    if (data.joinedSlugs.contains(id)) {
      final chatId = data.convoBySlug[id];
      if (chatId != null) context.push('/chat/$chatId');
      return;
    }
    setState(() => _followingId = id);
    try {
      final convo = await ref.read(chatRepositoryProvider).joinCommunity(id);
      if (!mounted) return;
      context.push('/chat/${convo.id}');
      setState(_load);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _followingId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(authProvider).user;
    final myName = (me?.name.isNotEmpty == true) ? me!.name : 'My status';
    final letter = myName.trim().isNotEmpty ? myName.trim()[0].toUpperCase() : 'M';

    return Scaffold(
      appBar: AppBar(
        title: _searching
            ? TextField(
                controller: _searchCtrl,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Search status or channels',
                  border: InputBorder.none,
                ),
                onChanged: (v) => setState(() => _query = v),
              )
            : const Text('Updates'),
        actions: [
          IconButton(
            tooltip: _searching ? 'Close search' : 'Search',
            onPressed: () {
              setState(() {
                _searching = !_searching;
                if (!_searching) {
                  _query = '';
                  _searchCtrl.clear();
                }
              });
            },
            icon: Icon(_searching ? Icons.close : Icons.search),
          ),
        ],
      ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FloatingActionButton.small(
            heroTag: 'status_text_fab',
            backgroundColor: Theme.of(context).brightness == Brightness.dark
                ? AppTheme.messengerElevated
                : const Color(0xFFF0F2F5),
            foregroundColor: AppTheme.accentGreen,
            onPressed: _composeText,
            child: const Icon(Icons.edit),
          ),
          const SizedBox(height: 12),
          FloatingActionButton(
            heroTag: 'status_camera_fab',
            onPressed: _pickStatusMedia,
            child: const Icon(Icons.photo_camera, color: Colors.black),
          ),
        ],
      ),
      body: FutureBuilder<_UpdatesData>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const LoadingView();
          }
          if (snapshot.hasError) {
            return ErrorView(message: '${snapshot.error}', onRetry: () => setState(_load));
          }
          final raw = snapshot.data!;
          final q = _query.trim().toLowerCase();
          final rings = q.isEmpty
              ? raw.rings
              : raw.rings.where((r) => r.name.toLowerCase().contains(q)).toList();
          final channels = q.isEmpty
              ? raw.channels
              : raw.channels.where((c) {
                  final name = c['name']?.toString().toLowerCase() ?? '';
                  final tag = c['tagline']?.toString().toLowerCase() ?? '';
                  return name.contains(q) || tag.contains(q);
                }).toList();
          final data = _UpdatesData(
            rings: rings,
            channels: channels,
            joinedSlugs: raw.joinedSlugs,
            convoBySlug: raw.convoBySlug,
          );
          final hasMine = data.rings.any((r) => r.isMine);
          final titleColor = Theme.of(context).colorScheme.onSurface;
          final muted = Theme.of(context).brightness == Brightness.dark
              ? AppTheme.messengerMuted
              : const Color(0xFF667781);

          return RefreshIndicator(
            color: AppTheme.accentGreen,
            onRefresh: () async => setState(_load),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(0, 8, 0, 120),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: Text(
                    'Status',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: titleColor,
                    ),
                  ),
                ),
                SizedBox(
                  height: 168,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    children: [
                      // Always lead with My status (tap opens ring or compose)
                      Builder(
                        builder: (_) {
                          _StatusRing? mine;
                          for (final r in data.rings) {
                            if (r.isMine) {
                              mine = r;
                              break;
                            }
                          }
                          return _StatusCard(
                            label: 'My status',
                            letter: letter,
                            hasUpdate: mine != null,
                            showAddBadge: true,
                            bgHex: mine != null && mine.items.isNotEmpty
                                ? mine.items.first['background_color']?.toString()
                                : null,
                            mediaUrl: mine != null && mine.items.isNotEmpty
                                ? mine.items.first['media_url']?.toString()
                                : null,
                            previewText: mine != null && mine.items.isNotEmpty
                                ? mine.items.first['body']?.toString()
                                : null,
                            onTap: () {
                              if (mine != null) {
                                _openRing(mine);
                              } else {
                                _composeText();
                              }
                            },
                            onAdd: _pickStatusMedia,
                          );
                        },
                      ),
                      ...data.rings.where((r) => !r.isMine).map(
                            (ring) => _StatusCard(
                              label: ring.name,
                              letter: ring.name.trim().isNotEmpty
                                  ? ring.name.trim()[0].toUpperCase()
                                  : 'W',
                              hasUpdate: true,
                              bgHex: ring.items.isNotEmpty
                                  ? ring.items.first['background_color']?.toString()
                                  : null,
                              mediaUrl: ring.items.isNotEmpty
                                  ? ring.items.first['media_url']?.toString()
                                  : null,
                              previewText: ring.items.isNotEmpty
                                  ? ring.items.first['body']?.toString()
                                  : null,
                              onTap: () => _openRing(ring),
                            ),
                          ),
                    ],
                  ),
                ),
                if (!hasMine && data.rings.isEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Text(
                      'No status yet — tap My status or the camera to post a 24h vibe.',
                      style: TextStyle(color: muted),
                    ),
                  ),
                const Divider(height: 24),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Channels',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: titleColor,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: () => context.go('/communities'),
                        child: const Text('Explore'),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Text(
                    'Find channels to follow — Kampala Campus, Cranes & Faith.',
                    style: TextStyle(color: muted, fontSize: 13),
                  ),
                ),
                ...data.channels.map((c) {
                  final id = c['id']?.toString() ?? '';
                  final hex = (c['color']?.toString() ?? '#0B6E4F').replaceAll('#', '');
                  final color = Color(int.parse('FF$hex', radix: 16));
                  final following = data.joinedSlugs.contains(id);
                  final busy = _followingId == id;
                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    leading: CircleAvatar(
                      radius: 26,
                      backgroundColor: color.withValues(alpha: 0.2),
                      foregroundColor: color,
                      child: Text(
                        (c['name']?.toString() ?? 'C')[0],
                        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 18),
                      ),
                    ),
                    title: Text(c['name']?.toString() ?? 'Channel'),
                    subtitle: Text(
                      '${c['members_label'] ?? ''} · ${c['tagline'] ?? ''}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: busy
                        ? const SizedBox(
                            width: 28,
                            height: 28,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : following
                            ? OutlinedButton(
                                onPressed: () => _followChannel(c, data),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: AppTheme.accentGreen,
                                  side: const BorderSide(color: AppTheme.accentGreen),
                                  visualDensity: VisualDensity.compact,
                                ),
                                child: const Text('Open'),
                              )
                            : FilledButton(
                                onPressed: () => _followChannel(c, data),
                                style: FilledButton.styleFrom(
                                  backgroundColor: AppTheme.accentGreen,
                                  foregroundColor: Colors.black,
                                  visualDensity: VisualDensity.compact,
                                ),
                                child: const Text('Follow'),
                              ),
                  );
                }),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: OutlinedButton.icon(
                    onPressed: () => context.go('/communities'),
                    icon: const Icon(Icons.explore_outlined),
                    label: const Text('Find channels to follow'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppTheme.accentGreen,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _UpdatesData {
  _UpdatesData({
    required this.rings,
    required this.channels,
    required this.joinedSlugs,
    required this.convoBySlug,
  });

  final List<_StatusRing> rings;
  final List<Map<String, dynamic>> channels;
  final Set<String> joinedSlugs;
  final Map<String, String> convoBySlug;
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.label,
    required this.letter,
    required this.onTap,
    this.hasUpdate = false,
    this.showAddBadge = false,
    this.onAdd,
    this.bgHex,
    this.mediaUrl,
    this.previewText,
  });

  final String label;
  final String letter;
  final VoidCallback onTap;
  final bool hasUpdate;
  final bool showAddBadge;
  final VoidCallback? onAdd;
  final String? bgHex;
  final String? mediaUrl;
  final String? previewText;

  @override
  Widget build(BuildContext context) {
    Color fill = AppTheme.messengerElevated;
    if (bgHex != null && bgHex!.isNotEmpty) {
      try {
        final hex = bgHex!.replaceAll('#', '');
        fill = Color(int.parse('FF$hex', radix: 16));
      } catch (_) {}
    }
    final dark = Theme.of(context).brightness == Brightness.dark;
    final hasImage = mediaUrl != null && mediaUrl!.isNotEmpty;
    final snippet = (previewText ?? '').trim();

    return Padding(
      padding: const EdgeInsets.only(right: 10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: SizedBox(
          width: 96,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Stack(
                children: [
                  Container(
                    width: 96,
                    height: 128,
                    decoration: BoxDecoration(
                      color: fill,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: hasUpdate ? AppTheme.accentGreen : (dark
                            ? const Color(0xFF3B4A54)
                            : const Color(0xFFD1D7DB)),
                        width: hasUpdate ? 2.5 : 1.5,
                      ),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: hasImage
                        ? Image.network(
                            resolveMediaUrl(mediaUrl!) ?? mediaUrl!,
                            fit: BoxFit.cover,
                            width: 96,
                            height: 128,
                            errorBuilder: (context, error, stackTrace) =>
                                _cardFallback(letter, snippet),
                          )
                        : _cardFallback(letter, snippet),
                  ),
                  if (showAddBadge)
                    Positioned(
                      right: 6,
                      bottom: 6,
                      child: Material(
                        color: AppTheme.accentGreen,
                        shape: const CircleBorder(),
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: onAdd ?? onTap,
                          child: const Padding(
                            padding: EdgeInsets.all(4),
                            child: Icon(Icons.add, size: 16, color: Colors.black),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: dark ? AppTheme.messengerMuted : const Color(0xFF667781),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _cardFallback(String letter, String snippet) {
    return Padding(
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 14,
            backgroundColor: Colors.white.withValues(alpha: 0.22),
            child: Text(
              letter,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
            ),
          ),
          const Spacer(),
          Text(
            snippet.isEmpty ? 'Add status' : snippet,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.95),
              fontSize: 12,
              fontWeight: FontWeight.w600,
              height: 1.25,
            ),
          ),
        ],
      ),
    );
  }
}
