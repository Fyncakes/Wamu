import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/app_theme.dart';

/// Help centre (You tab).
class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key});

  static final _supportUri = Uri(
    scheme: 'mailto',
    path: 'support@wamu.ug',
    queryParameters: {'subject': 'Wamu support'},
  );

  @override
  Widget build(BuildContext context) {
    final faqs = const [
      (
        'How do I sign in?',
        'Enter your Ugandan (+256) phone number for a one-time SMS code, or tap Scan to sign in and scan My QR code from a device already logged in. The QR never includes your password or phone number.',
      ),
      (
        'How do I link another phone?',
        'On a logged-in phone: You → My QR code. On the new phone: Scan to sign in. To point the app at a PC/tunnel server, use You → Wamu server (or the computer’s /connect page).',
      ),
      (
        'How do I get UI changes without a new APK?',
        'On the same Wi‑Fi as the PC, open Chrome at the demo URL (You → Live updates). After the PC runs ./infrastructure/phone_demo_rebuild_web.sh, pull to refresh or hard-refresh. Rebuild the APK only for native plugins (camera, FCM, WebRTC).',
      ),
      (
        'How do I save data?',
        'You → Data saver, and Storage and data → turn photos off on mobile data.',
      ),
      (
        'Who can see I am online?',
        'You → Privacy — toggle last seen and online status.',
      ),
      (
        'Where is the marketplace?',
        'Videos is the home tab — browse shops from the storefront icon. Orders live under the Orders tab; favourites are under You.',
      ),
      (
        'Video calls not connecting?',
        'Allow Camera and Microphone when asked. Both phones need a working network; same Wi‑Fi works best.',
      ),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('Help')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(0, 8, 0, 32),
        children: [
          const ListTile(
            leading: Icon(Icons.info_outline, color: AppTheme.accentGreen),
            title: Text("Uganda's Digital Home"),
            subtitle: Text('Connect. Discover. Shop. Move. Grow.'),
          ),
          const Divider(),
          ...faqs.map(
            (f) => ExpansionTile(
              leading: const Icon(Icons.help_outline, color: AppTheme.accentGreen),
              title: Text(f.$1),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(f.$2),
                  ),
                ),
              ],
            ),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.mail_outline, color: AppTheme.accentGreen),
            title: const Text('Email support'),
            subtitle: const Text('support@wamu.ug'),
            onTap: () async {
              final ok = await launchUrl(_supportUri);
              if (!context.mounted) return;
              if (!ok) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('No email app found — write to support@wamu.ug')),
                );
              }
            },
          ),
        ],
      ),
    );
  }
}
