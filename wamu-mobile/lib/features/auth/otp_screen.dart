import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/storage/secure_storage.dart';
import '../../core/theme/app_theme.dart';
import 'auth_provider.dart';

/// OTP verification — code sent to the user's phone.
class OtpScreen extends ConsumerStatefulWidget {
  const OtpScreen({super.key, required this.phone});

  final String phone;

  @override
  ConsumerState<OtpScreen> createState() => _OtpScreenState();
}

class _OtpScreenState extends ConsumerState<OtpScreen> {
  final _otpController = TextEditingController();
  bool _loading = false;
  late String _phone = widget.phone;

  @override
  void initState() {
    super.initState();
    _resolvePhone();
  }

  Future<void> _resolvePhone() async {
    if (_phone.trim().isNotEmpty) return;
    final saved = await ref.read(secureStorageProvider).getPhone();
    if (saved != null && saved.isNotEmpty && mounted) {
      setState(() => _phone = saved);
    }
  }

  @override
  void dispose() {
    _otpController.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    if (_phone.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Missing phone number — go back and try again')),
      );
      return;
    }
    setState(() => _loading = true);
    try {
      await ref.read(authProvider.notifier).verifyOtp(_phone, _otpController.text.trim());
      if (!mounted) return;
      final auth = ref.read(authProvider);
      if (auth.status == AuthStatus.needsProfile) {
        context.go('/profile-setup');
      } else {
        context.go('/chats');
      }
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
    return Scaffold(
      appBar: AppBar(title: Text('Verify your number')),
      body: Padding(
        padding: EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Enter the 6-digit code we sent to',
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            SizedBox(height: 6),
            Text(
              _phone.isEmpty ? '…' : _phone,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: AppTheme.accentGreen,
                    fontWeight: FontWeight.w700,
                  ),
            ),
            SizedBox(height: 28),
            TextField(
              controller: _otpController,
              keyboardType: TextInputType.number,
              maxLength: 6,
              autofocus: true,
              textAlign: TextAlign.center,
              style: TextStyle(letterSpacing: 8, fontSize: 24, fontWeight: FontWeight.w700),
              decoration: InputDecoration(
                labelText: 'Verification code',
                counterText: '',
              ),
              onSubmitted: (_) => _verify(),
            ),
            SizedBox(height: 12),
            Text(
              'For this trial, enter 123456.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppTheme.muted(context),
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            TextButton(
              onPressed: _loading || _phone.isEmpty
                  ? null
                  : () async {
                      setState(() => _loading = true);
                      try {
                        await ref.read(authProvider.notifier).requestOtp(_phone);
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Code sent again')),
                          );
                        }
                      } catch (e) {
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('$e')),
                          );
                        }
                      } finally {
                        if (mounted) setState(() => _loading = false);
                      }
                    },
              child: const Text('Resend code'),
            ),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: _loading ? null : _verify,
              child: _loading
                  ? const SizedBox(
                      height: 22,
                      width: 22,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Text('Verify & continue'),
            ),
          ],
        ),
      ),
    );
  }
}
