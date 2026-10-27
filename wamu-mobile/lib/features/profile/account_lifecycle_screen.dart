import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_client.dart';
import '../../core/theme/app_theme.dart';
import '../auth/auth_provider.dart';

/// You → Account → Deactivate or permanently delete.
class AccountLifecycleScreen extends ConsumerStatefulWidget {
  const AccountLifecycleScreen({super.key});

  @override
  ConsumerState<AccountLifecycleScreen> createState() => _AccountLifecycleScreenState();
}

class _AccountLifecycleScreenState extends ConsumerState<AccountLifecycleScreen> {
  bool _busy = false;

  Future<void> _deactivate() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Deactivate account?'),
        content: const Text(
          'You will be signed out. Your number stays on Wamu. Sign in again with the SMS code to turn the account back on.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Deactivate'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref.read(apiClientProvider).post('/users/me/deactivate');
      await ref.read(authProvider.notifier).logout();
      if (!mounted) return;
      context.go('/login');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Account deactivated. Sign in again anytime.')),
      );
    } on DioException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_err(e, 'Could not deactivate'))),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final controller = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete account?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'This removes your profile, chats content, shops, and rider data from Wamu. Payment records stay for the ledger. Type DELETE to confirm.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'Type DELETE',
                border: OutlineInputBorder(),
              ),
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () {
              if (controller.text.trim().toUpperCase() == 'DELETE') {
                Navigator.pop(ctx, true);
              }
            },
            child: const Text('Delete forever'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref.read(apiClientProvider).post(
        '/users/me/delete',
        data: {'confirm': 'DELETE'},
      );
      await ref.read(authProvider.notifier).logout();
      if (!mounted) return;
      context.go('/login');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Your Wamu account was deleted.')),
      );
    } on DioException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_err(e, 'Could not delete account'))),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _err(DioException e, String fallback) {
    final detail = e.response?.data;
    if (detail is Map && detail['detail'] != null) return detail['detail'].toString();
    return fallback;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Account')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          ListTile(
            leading: const Icon(Icons.person_outline),
            title: const Text('Edit profile'),
            subtitle: const Text('Name, photo, about'),
            onTap: _busy ? null : () => context.push('/edit-profile'),
          ),
          const Divider(height: 24),
          ListTile(
            leading: const Icon(Icons.pause_circle_outline),
            title: const Text('Deactivate account'),
            subtitle: const Text('Hide your account. Sign in later to restore it.'),
            enabled: !_busy,
            onTap: _deactivate,
          ),
          ListTile(
            leading: const Icon(Icons.delete_forever_outlined, color: Colors.redAccent),
            title: const Text(
              'Delete account',
              style: TextStyle(color: Colors.redAccent),
            ),
            subtitle: const Text(
              'Remove your personal data from Wamu. This cannot be undone.',
            ),
            enabled: !_busy,
            onTap: _delete,
          ),
          if (_busy)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(
                child: CircularProgressIndicator(color: AppTheme.accentGreen),
              ),
            ),
        ],
      ),
    );
  }
}
