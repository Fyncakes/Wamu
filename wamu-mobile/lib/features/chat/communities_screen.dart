import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_client.dart';
import '../../shared/utils/phone_normalize.dart';
import '../../shared/widgets/error_view.dart';
import '../../shared/widgets/loading_view.dart';
import 'chat_repository.dart';

/// Uganda youth communities — Join opens a real GROUP chat.
class CommunitiesScreen extends ConsumerStatefulWidget {
  const CommunitiesScreen({super.key});

  @override
  ConsumerState<CommunitiesScreen> createState() => _CommunitiesScreenState();
}

class _CommunitiesScreenState extends ConsumerState<CommunitiesScreen> {
  late Future<List<Map<String, dynamic>>> _future;
  String? _joiningId;
  String? _leavingId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _future = () async {
      final res = await ref.read(apiClientProvider).get('/communities');
      final data = res.data;
      if (data is Map && data['items'] is List) {
        return (data['items'] as List).cast<Map<String, dynamic>>();
      }
      return <Map<String, dynamic>>[];
    }();
  }

  Future<void> _openOrJoin(Map<String, dynamic> community) async {
    final id = community['id']?.toString();
    if (id == null) return;
    setState(() => _joiningId = id);
    try {
      final convo = await ref.read(chatRepositoryProvider).joinCommunity(id);
      if (!mounted) return;
      setState(_load);
      context.push('/chat/${convo.id}');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _joiningId = null);
    }
  }

  Future<void> _leave(Map<String, dynamic> community) async {
    final id = community['id']?.toString();
    if (id == null) return;
    setState(() => _leavingId = id);
    try {
      await ref.read(chatRepositoryProvider).leaveCommunity(id);
      if (!mounted) return;
      setState(_load);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Left community')),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _leavingId = null);
    }
  }

  Future<void> _createGroup() async {
    final nameController = TextEditingController();
    final phonesController = TextEditingController(text: '+256700000004');
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('New group', style: Theme.of(ctx).textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(
                'Invite friends by +256 number (comma-separated).',
                style: Theme.of(ctx).textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: 'Group name',
                  hintText: 'Hostel 5 crew',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: phonesController,
                decoration: const InputDecoration(
                  labelText: 'Member phones',
                  hintText: '+2567…, +2567…',
                ),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Create group'),
              ),
            ],
          ),
        );
      },
    );
    final title = nameController.text.trim();
    final phonesRaw = phonesController.text;
    nameController.dispose();
    phonesController.dispose();
    if (ok != true || title.length < 2) return;

    final phones = phonesRaw
        .split(RegExp(r'[,;\s]+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .map(normalizeUgPhone)
        .toList();

    try {
      final convo = await ref.read(chatRepositoryProvider).createGroup(
            title: title,
            memberPhones: phones,
          );
      if (!mounted) return;
      context.push('/chat/${convo.id}');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Communities')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createGroup,
        icon: const Icon(Icons.group_add),
        label: const Text('New group'),
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const LoadingView();
          }
          if (snapshot.hasError) {
            return ErrorView(message: '${snapshot.error}', onRetry: () => setState(_load));
          }
          final items = snapshot.data ?? [];
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
            children: [
              Text(
                'Find your people',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 4),
              Text(
                'Campus crews, hustles, football, faith — join live groups or open ones you already joined.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              ...items.map((c) {
                final hex = (c['color']?.toString() ?? '#0B6E4F').replaceAll('#', '');
                final color = Color(int.parse('FF$hex', radix: 16));
                final topics = (c['topics'] as List?)?.map((e) => e.toString()).toList() ?? [];
                final id = c['id']?.toString();
                final joining = _joiningId == id;
                final leaving = _leavingId == id;
                final joined = c['joined'] == true;
                return Card(
                  margin: const EdgeInsets.only(bottom: 12),
                  child: ListTile(
                    contentPadding: const EdgeInsets.all(16),
                    leading: CircleAvatar(
                      backgroundColor: color.withValues(alpha: 0.15),
                      foregroundColor: color,
                      child: Text((c['name']?.toString() ?? 'C')[0]),
                    ),
                    title: Text(c['name']?.toString() ?? 'Community'),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 4),
                        Text('${c['city']} · ${c['members_label']}'),
                        const SizedBox(height: 4),
                        Text(c['tagline']?.toString() ?? ''),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 6,
                          children: topics
                              .map(
                                (t) => Chip(
                                  label: Text(t, style: const TextStyle(fontSize: 12)),
                                  visualDensity: VisualDensity.compact,
                                  padding: EdgeInsets.zero,
                                ),
                              )
                              .toList(),
                        ),
                      ],
                    ),
                    isThreeLine: true,
                    trailing: joining || leaving
                        ? const SizedBox(
                            width: 28,
                            height: 28,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : joined
                            ? Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  TextButton(
                                    onPressed: () => _openOrJoin(c),
                                    child: const Text('Open'),
                                  ),
                                  TextButton(
                                    onPressed: () => _leave(c),
                                    child: Text(
                                      'Leave',
                                      style: TextStyle(color: Colors.red.shade700, fontSize: 12),
                                    ),
                                  ),
                                ],
                              )
                            : TextButton(
                                onPressed: () => _openOrJoin(c),
                                child: const Text('Join'),
                              ),
                  ),
                );
              }),
            ],
          );
        },
      ),
    );
  }
}
