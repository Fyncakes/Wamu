import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config.dart';
import '../../core/device_link.dart';
import '../../core/server_config.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/utils/phone_normalize.dart';
import '../../shared/widgets/wamu_logo.dart';
import 'auth_provider.dart';
import 'qr_scan_page.dart';

/// Phone login — branded welcome into Wamu.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _phoneController = TextEditingController(text: '+256');
  final _formKey = GlobalKey<FormState>();
  bool _loading = false;

  @override
  void dispose() {
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (ServerConfig.needsSetup) {
      context.go('/server-setup');
      return;
    }
    setState(() => _loading = true);
    try {
      final phone = normalizeUgPhone(_phoneController.text);
      await ref.read(authProvider.notifier).requestOtp(phone);
      if (mounted) context.push('/otp', extra: phone);
    } catch (e) {
      if (mounted) {
        final msg = e.toString();
        final hint = msg.contains('SocketException') ||
                msg.contains('connection') ||
                msg.contains('Failed host') ||
                msg.contains('timed out') ||
                msg.contains('Cannot reach')
            ? 'Cannot reach the server. Open Wamu server and scan the QR or paste your Wamu URL.'
            : 'Could not send code: $e';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(hint), duration: const Duration(seconds: 8)),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _scanAccountQr() async {
    if (kIsWeb) {
      final pasted = await _promptPaste();
      if (pasted == null || pasted.isEmpty || !mounted) return;
      await _applyScanned(pasted);
      return;
    }
    final raw = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => const QrScanPage(hint: 'Scan My QR code on your other Wamu device'),
      ),
    );
    if (raw == null || raw.trim().isEmpty || !mounted) return;
    await _applyScanned(raw.trim());
  }

  Future<String?> _promptPaste() {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Paste sign-in code'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Paste the link from My QR code',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Sign in'),
          ),
        ],
      ),
    ).whenComplete(controller.dispose);
  }

  Future<void> _applyScanned(String raw) async {
    setState(() => _loading = true);
    try {
      final parsed = parseWamuQr(raw);
      if (parsed.apiBaseUrl != null && parsed.apiBaseUrl!.trim().isNotEmpty) {
        await ref.read(serverConfigProvider.notifier).setServerUrl(parsed.apiBaseUrl!);
      }
      if (!parsed.isAccountLink) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'That QR only points at the Wamu server. Scan My QR code on a signed-in device to join this account.',
              ),
            ),
          );
        }
        return;
      }
      await ref.read(authProvider.notifier).claimDeviceLink(
            parsed.accountToken!,
            deviceName: kIsWeb ? 'Wamu web' : 'Wamu phone',
          );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e'), duration: const Duration(seconds: 8)),
        );
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
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: dark
                ? const [Color(0xFF0B141A), Color(0xFF0D3B2E), Color(0xFF0B141A)]
                : const [Color(0xFFE8F7EF), Color(0xFFFFFBF7), Color(0xFFF5E6D3)],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: () => context.push('/server-setup', extra: true),
                      icon: const Icon(Icons.dns_outlined, size: 18),
                      label: const Text('Wamu server'),
                    ),
                  ),
                  const Spacer(),
                  const WamuLogo(size: 96),
                  const SizedBox(height: 20),
                  Text(
                    AppConfig.appName,
                    style: AppTheme.brandHero.copyWith(fontSize: 42),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    AppConfig.tagline,
                    style: AppTheme.tagline.copyWith(fontSize: 16),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    AppConfig.supportLine,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: dark ? AppTheme.messengerMuted : AppTheme.warmBrown,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 36),
                  Text(
                    'Your phone number',
                    style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: _phoneController,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(
                      hintText: '+256 7XX XXX XXX',
                      prefixIcon: Icon(Icons.phone_iphone),
                    ),
                    validator: (v) =>
                        v != null && isValidUgPhone(v) ? null : 'Enter a valid Ugandan number',
                  ),
                  const SizedBox(height: 18),
                  ElevatedButton(
                    onPressed: _loading ? null : _submit,
                    child: _loading
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Text('Continue'),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _loading ? null : _scanAccountQr,
                    icon: const Icon(Icons.qr_code_scanner),
                    label: Text(kIsWeb ? 'Paste account QR link' : 'Scan to sign in'),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    'Demo OTP is 123456.',
                    style: theme.textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                  const Spacer(flex: 2),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
