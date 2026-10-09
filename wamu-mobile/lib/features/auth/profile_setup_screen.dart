import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';
import 'auth_provider.dart';

/// First-run welcome + display name before entering the app.
class ProfileSetupScreen extends ConsumerStatefulWidget {
  const ProfileSetupScreen({super.key});

  @override
  ConsumerState<ProfileSetupScreen> createState() => _ProfileSetupScreenState();
}

class _ProfileSetupScreenState extends ConsumerState<ProfileSetupScreen> {
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  bool _loading = false;

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    setState(() => _loading = true);
    try {
      await ref.read(authProvider.notifier).completeProfile(
            name,
            email: _emailController.text.trim().isEmpty ? null : _emailController.text.trim(),
          );
      if (mounted) context.go('/chats');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: dark
                ? const [Color(0xFF0B141A), Color(0xFF0D3B2E)]
                : const [Color(0xFFE8F7EF), Color(0xFFFFFBF7)],
          ),
        ),
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 32, 24, 32),
            children: [
              Text(
                'Welcome to Wamu',
                style: AppTheme.brandHero.copyWith(fontSize: 34),
              ),
              const SizedBox(height: 8),
              Text(
                'Find local shops, chat to order, pay, and get delivery.',
                style: theme.textTheme.bodyLarge,
              ),
              const SizedBox(height: 28),
              _WelcomePill(
                icon: Icons.chat_bubble_rounded,
                title: 'Chats first',
                body: 'Message friends and shops in one place.',
                dark: dark,
              ),
              const SizedBox(height: 10),
              _WelcomePill(
                icon: Icons.storefront_rounded,
                title: 'Discover Kampala',
                body: 'Browse cakes, fashion, phones, and markets nearby.',
                dark: dark,
              ),
              const SizedBox(height: 10),
              _WelcomePill(
                icon: Icons.groups_rounded,
                title: 'Communities',
                body: 'Join campus, creatives, and Cranes channels.',
                dark: dark,
              ),
              const SizedBox(height: 32),
              Text('What should we call you?', style: theme.textTheme.titleMedium),
              const SizedBox(height: 12),
              TextField(
                controller: _nameController,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Full name',
                  prefixIcon: Icon(Icons.person_outline),
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: 'Email (optional)',
                  prefixIcon: Icon(Icons.mail_outline),
                ),
              ),
              const SizedBox(height: 28),
              ElevatedButton(
                onPressed: _loading ? null : _submit,
                child: _loading
                    ? const SizedBox(
                        height: 22,
                        width: 22,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Text('Enter Wamu'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WelcomePill extends StatelessWidget {
  const _WelcomePill({
    required this.icon,
    required this.title,
    required this.body,
    required this.dark,
  });

  final IconData icon;
  final String title;
  final String body;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: dark ? AppTheme.messengerElevated : Colors.white.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor: AppTheme.accentGreen.withValues(alpha: 0.2),
            child: Icon(icon, color: AppTheme.accentGreen),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(body, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
