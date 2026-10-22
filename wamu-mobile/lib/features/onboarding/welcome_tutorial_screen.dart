import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';
import '../../shared/widgets/wamu_logo.dart';
import 'tutorial_prefs.dart';

/// First-run product tour — maps to real Wamu tabs (Videos, Chats, Shops, Orders, You).
class WelcomeTutorialScreen extends ConsumerStatefulWidget {
  const WelcomeTutorialScreen({super.key, this.replay = false});

  final bool replay;

  @override
  ConsumerState<WelcomeTutorialScreen> createState() =>
      _WelcomeTutorialScreenState();
}

class _WelcomeTutorialScreenState extends ConsumerState<WelcomeTutorialScreen> {
  final _page = PageController();
  int _index = 0;

  static const _steps = <_TutorialStep>[
    _TutorialStep(
      icon: Icons.waving_hand_rounded,
      title: 'Welcome to Wamu',
      body:
          'Chat with people, discover local shops, shop with MoMo, and get delivery — all in one Uganda-first app.',
      isWelcome: true,
    ),
    _TutorialStep(
      icon: Icons.video_library_outlined,
      title: 'Discover Wamu',
      body:
          'The Videos tab is home. Swipe short shop videos, then use the bottom bar to jump to Chats, Shops, Orders, or You.',
      tip: 'Tip: swipe left/right on the bottom tabs too.',
    ),
    _TutorialStep(
      icon: Icons.chat_bubble_outline_rounded,
      title: 'Connect and chat',
      body:
          'Open Chats to message friends and shops. Start a new chat, join communities, or continue an order conversation.',
      tip: 'Shops often confirm orders inside chat.',
    ),
    _TutorialStep(
      icon: Icons.storefront_outlined,
      title: 'Discover businesses',
      body:
          'Shops shows nearby merchants and products. Open a shop profile, browse the catalogue, and watch their short videos when available.',
    ),
    _TutorialStep(
      icon: Icons.shopping_bag_outlined,
      title: 'Shop and order',
      body:
          'Add products to your cart, review quantities, and place an order. You can also order while chatting with a shop.',
      tip: 'Orders appear under the Orders tab.',
    ),
    _TutorialStep(
      icon: Icons.payments_outlined,
      title: 'Payments and delivery',
      body:
          'Pay with MTN MoMo (Airtel Money when we enable it on your build). Track status on Orders — merchants prepare, then riders deliver when you choose delivery.',
      tip: 'Use a Uganda mobile-money number you control.',
    ),
    _TutorialStep(
      icon: Icons.person_outline_rounded,
      title: 'Your account',
      body:
          'You is your profile hub: edit profile, privacy, notifications, help, and roles (buy, sell, or deliver) on the same account.',
      tip: 'Reopen this tour anytime from Help.',
    ),
  ];

  Future<void> _finish() async {
    if (!widget.replay) {
      await ref.read(tutorialControllerProvider).markCompleted();
    }
    if (!mounted) return;
    context.go('/home');
  }

  void _next() {
    if (_index >= _steps.length - 1) {
      _finish();
      return;
    }
    _page.nextPage(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  void _back() {
    if (_index <= 0) return;
    _page.previousPage(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void dispose() {
    _page.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final step = _steps[_index];
    final isLast = _index == _steps.length - 1;
    final progressLabel = step.isWelcome
        ? 'Welcome'
        : 'Step $_index of ${_steps.length - 1}';

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
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                child: Row(
                  children: [
                    if (_index > 0)
                      TextButton(onPressed: _back, child: const Text('Back'))
                    else
                      const SizedBox(width: 64),
                    Expanded(
                      child: Text(
                        progressLabel,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: AppTheme.messengerMuted,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: _finish,
                      child: Text(widget.replay ? 'Close' : 'Skip'),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: PageView.builder(
                  controller: _page,
                  itemCount: _steps.length,
                  onPageChanged: (i) => setState(() => _index = i),
                  itemBuilder: (context, i) {
                    final s = _steps[i];
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(28, 12, 28, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Spacer(flex: 1),
                          if (s.isWelcome) ...[
                            const WamuLogo(size: 88),
                            const SizedBox(height: 20),
                            Text(
                              'Wamu',
                              textAlign: TextAlign.center,
                              style: AppTheme.brandHero.copyWith(fontSize: 40),
                            ),
                          ] else
                            Center(
                              child: CircleAvatar(
                                radius: 44,
                                backgroundColor:
                                    AppTheme.accentGreen.withValues(alpha: 0.18),
                                child: Icon(
                                  s.icon,
                                  size: 40,
                                  color: AppTheme.accentGreen,
                                ),
                              ),
                            ),
                          const SizedBox(height: 24),
                          Text(
                            s.title,
                            textAlign: TextAlign.center,
                            style: theme.textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            s.body,
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyLarge?.copyWith(
                              height: 1.45,
                            ),
                          ),
                          if (s.tip != null) ...[
                            const SizedBox(height: 18),
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                color: dark
                                    ? AppTheme.messengerElevated
                                    : Colors.white.withValues(alpha: 0.85),
                              ),
                              child: Text(
                                s.tip!,
                                textAlign: TextAlign.center,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: AppTheme.messengerMuted,
                                ),
                              ),
                            ),
                          ],
                          const Spacer(flex: 2),
                        ],
                      ),
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (var i = 0; i < _steps.length; i++)
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        margin: const EdgeInsets.symmetric(horizontal: 3),
                        height: 8,
                        width: i == _index ? 22 : 8,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          color: i == _index
                              ? AppTheme.accentGreen
                              : AppTheme.accentGreen.withValues(alpha: 0.28),
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _next,
                    child: Text(
                      step.isWelcome
                          ? 'Get Started'
                          : isLast
                              ? (widget.replay ? 'Done' : 'Enter Wamu')
                              : 'Next',
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TutorialStep {
  const _TutorialStep({
    required this.icon,
    required this.title,
    required this.body,
    this.tip,
    this.isWelcome = false,
  });

  final IconData icon;
  final String title;
  final String body;
  final String? tip;
  final bool isWelcome;
}
