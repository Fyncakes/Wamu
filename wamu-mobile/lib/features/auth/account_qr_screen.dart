import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/theme/app_theme.dart';
import 'auth_provider.dart';

/// Logged-in user’s rotating QR so another device can join this account.
class AccountQrScreen extends ConsumerStatefulWidget {
  const AccountQrScreen({super.key});

  @override
  ConsumerState<AccountQrScreen> createState() => _AccountQrScreenState();
}

class _AccountQrScreenState extends ConsumerState<AccountQrScreen> {
  String? _qr;
  String? _linkId;
  String? _error;
  bool _claimed = false;
  String? _claimedDevice;
  Timer? _poll;
  Timer? _rotate;

  @override
  void initState() {
    super.initState();
    _mint();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _rotate?.cancel();
    unawaited(ref.read(authRepositoryProvider).revokeDeviceLinks());
    super.dispose();
  }

  Future<void> _mint() async {
    _poll?.cancel();
    _rotate?.cancel();
    setState(() {
      _error = null;
      _claimed = false;
      _claimedDevice = null;
    });
    try {
      final created = await ref.read(authRepositoryProvider).createDeviceLink();
      if (!mounted) return;
      setState(() {
        _qr = created.qr;
        _linkId = created.id;
      });
      _poll = Timer.periodic(const Duration(seconds: 2), (_) => _checkStatus());
      _rotate = Timer(Duration(seconds: created.expiresIn), () {
        if (mounted && !_claimed) _mint();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  Future<void> _checkStatus() async {
    final id = _linkId;
    if (id == null || _claimed) return;
    try {
      final status = await ref.read(authRepositoryProvider).deviceLinkStatus(id);
      if (!mounted) return;
      if (status.status == 'claimed') {
        _poll?.cancel();
        _rotate?.cancel();
        setState(() {
          _claimed = true;
          _claimedDevice = status.deviceName;
        });
      } else if (status.status == 'expired') {
        await _mint();
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authProvider).user;
    final name = (user?.name.isNotEmpty == true) ? user!.name : 'Wamu';
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('My QR code')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 40),
        children: [
          Text(
            'Let another phone sign in as you',
            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            'Open Wamu on the new device → Scan to sign in. '
            'This code is not a password and does not include your phone number. It expires in about 2 minutes.',
            style: theme.textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 28),
          Center(
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
              ),
              child: _claimed
                  ? SizedBox(
                      width: 220,
                      height: 220,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.check_circle, color: AppTheme.accentGreen, size: 64),
                          const SizedBox(height: 12),
                          Text(
                            _claimedDevice == null || _claimedDevice!.isEmpty
                                ? 'Device connected'
                                : 'Connected: $_claimedDevice',
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.black87, fontWeight: FontWeight.w700),
                          ),
                        ],
                      ),
                    )
                  : _qr == null
                      ? SizedBox(
                          width: 220,
                          height: 220,
                          child: Center(
                            child: _error != null
                                ? Text(_error!, textAlign: TextAlign.center)
                                : const CircularProgressIndicator(),
                          ),
                        )
                      : QrImageView(
                          data: _qr!,
                          size: 220,
                          backgroundColor: Colors.white,
                        ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            name,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleLarge,
          ),
          const SizedBox(height: 28),
          OutlinedButton(
            onPressed: _mint,
            child: Text(_claimed ? 'Connect another device' : 'Refresh code'),
          ),
        ],
      ),
    );
  }
}
