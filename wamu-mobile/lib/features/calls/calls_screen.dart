import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../shared/widgets/error_view.dart';
import '../../shared/widgets/loading_view.dart';
import 'active_call_screen.dart';
import 'calls_repository.dart';

/// Call history. Incoming rings are handled globally by [IncomingCallHost].
class CallsScreen extends ConsumerStatefulWidget {
  const CallsScreen({super.key});

  @override
  ConsumerState<CallsScreen> createState() => _CallsScreenState();
}

class _CallsScreenState extends ConsumerState<CallsScreen> {
  late Future<List<CallModel>> _future;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _future = ref.read(callsRepositoryProvider).history();
  }

  String _subtitle(CallModel c) {
    final dir = c.isIncoming ? 'Incoming' : 'Outgoing';
    return '$dir · ${c.callType.toLowerCase()} · ${c.status.toLowerCase()}';
  }

  Future<void> _callBack(CallModel c) async {
    final peerId = c.isIncoming ? c.callerId : c.calleeId;
    if (peerId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cannot call back — missing peer')),
      );
      return;
    }
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.call),
              title: Text('Voice call ${c.peerName ?? ''}'),
              onTap: () => Navigator.pop(ctx, 'VOICE'),
            ),
            ListTile(
              leading: const Icon(Icons.videocam),
              title: Text('Video call ${c.peerName ?? ''}'),
              onTap: () => Navigator.pop(ctx, 'VIDEO'),
            ),
            ListTile(
              leading: const Icon(Icons.close),
              title: const Text('Cancel'),
              onTap: () => Navigator.pop(ctx),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    try {
      final call = await ref.read(callsRepositoryProvider).start(
            calleeId: peerId,
            conversationId: c.conversationId,
            callType: choice,
          );
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ActiveCallScreen(
            callId: call.id,
            isCaller: true,
            peerName: c.peerName ?? 'Wamu user',
            video: choice == 'VIDEO',
          ),
        ),
      );
      setState(_load);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Calls')),
      body: FutureBuilder<List<CallModel>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const LoadingView();
          }
          if (snapshot.hasError) {
            return ErrorView(message: '${snapshot.error}', onRetry: () => setState(_load));
          }
          final calls = snapshot.data ?? [];
          if (calls.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.call, size: 56, color: theme.colorScheme.primary),
                    const SizedBox(height: 12),
                    Text('No calls yet', style: theme.textTheme.titleLarge),
                    const SizedBox(height: 8),
                    Text(
                      'Open a chat and tap the phone or video icon to call.\n'
                      'Allow Camera and Microphone when prompted — same Wi‑Fi works best.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: () => context.go('/chats'),
                      child: const Text('Go to Chats'),
                    ),
                  ],
                ),
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: () async => setState(_load),
            child: ListView.separated(
              itemCount: calls.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final c = calls[index];
                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.12),
                    foregroundColor: theme.colorScheme.primary,
                    child: Icon(c.isVideo ? Icons.videocam : Icons.call),
                  ),
                  title: Text(c.peerName ?? 'Wamu user'),
                  subtitle: Text(_subtitle(c)),
                  trailing: Icon(
                    c.isIncoming ? Icons.call_received : Icons.call_made,
                    color: c.status == 'MISSED' || c.status == 'REJECTED'
                        ? theme.colorScheme.error
                        : theme.colorScheme.primary,
                  ),
                  onTap: () => _callBack(c),
                );
              },
            ),
          );
        },
      ),
    );
  }
}
