import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/device_link.dart';
import '../../core/server_config.dart';
import '../../core/theme/app_theme.dart';
import 'qr_scan_page.dart';

/// Link this phone to your Wamu server (QR scan or paste URL).
class ServerSetupScreen extends ConsumerStatefulWidget {
  const ServerSetupScreen({super.key, this.fromSettings = false});

  final bool fromSettings;

  @override
  ConsumerState<ServerSetupScreen> createState() => _ServerSetupScreenState();
}

class _ServerSetupScreenState extends ConsumerState<ServerSetupScreen> {
  late final TextEditingController _controller;
  bool _busy = false;
  String? _status;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: ServerConfig.needsSetup ? '' : ServerConfig.apiBaseUrl,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text != null && text.isNotEmpty) {
      setState(() => _controller.text = text);
    }
  }

  Future<void> _scanQr() async {
    if (kIsWeb) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('QR scan works in the Android app — paste the URL here on web.')),
      );
      return;
    }
    final raw = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => const QrScanPage(hint: 'Point at the QR on your computer screen'),
      ),
    );
    if (raw == null || raw.trim().isEmpty || !mounted) return;
    final parsed = parseWamuQr(raw.trim());
    setState(() => _controller.text = parsed.apiBaseUrl ?? raw.trim());
    await _testAndSave();
  }

  Future<void> _testAndSave() async {
    setState(() {
      _busy = true;
      _status = 'Connecting…';
    });
    try {
      var normalized = normalizeApiBaseUrl(_controller.text);
      // On Flutter web, prefer localhost over 127.0.0.1 when the page is localhost
      // (browsers treat them as different origins for CORS).
      if (kIsWeb) {
        final pageHost = Uri.base.host;
        final api = Uri.parse(normalized);
        if ((pageHost == 'localhost' || pageHost == '127.0.0.1') &&
            api.host != pageHost &&
            (api.host == 'localhost' || api.host == '127.0.0.1')) {
          normalized =
              '${api.scheme}://$pageHost${api.hasPort ? ':${api.port}' : ''}${api.path}';
          _controller.text = normalized;
        }
      }
      final healthUrl = '$normalized/health';
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 20),
      ));
      final res = await dio.get(healthUrl);
      if (res.statusCode != 200) {
        throw Exception('Health check failed (${res.statusCode})');
      }
      await ref.read(serverConfigProvider.notifier).setServerUrl(normalized);
      if (!mounted) return;
      setState(() => _status = 'Linked to Wamu');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Device linked — you can sign in')),
      );
      if (widget.fromSettings) {
        context.pop();
      } else {
        context.go('/login');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = '$e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not reach server: $e'),
          duration: const Duration(seconds: 8),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Wamu server'),
        automaticallyImplyLeading: widget.fromSettings,
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: dark
                ? const [Color(0xFF0B141A), Color(0xFF111B21)]
                : const [Color(0xFFE8F7EF), Color(0xFFFFFBF7)],
          ),
        ),
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text('Connect to Wamu', style: AppTheme.brandHero.copyWith(fontSize: 28)),
              const SizedBox(height: 8),
              Text(
                'Scan the QR on your computer’s /connect page, or paste the link below. '
                'You only need to do this once per phone.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: _busy ? null : _scanQr,
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('Scan QR code'),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(child: Divider(color: dark ? AppTheme.messengerMuted : null)),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text('or paste', style: theme.textTheme.bodySmall),
                  ),
                  Expanded(child: Divider(color: dark ? AppTheme.messengerMuted : null)),
                ],
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _controller,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Wamu link',
                  hintText: 'https://your-wamu-host',
                  prefixIcon: Icon(Icons.link),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _paste,
                    icon: const Icon(Icons.paste),
                    label: const Text('Paste'),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _busy ? null : _testAndSave,
                      child: _busy
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : const Text('Connect'),
                    ),
                  ),
                ],
              ),
              if (_status != null) ...[
                const SizedBox(height: 16),
                Text(_status!, style: theme.textTheme.bodySmall),
              ],
              const SizedBox(height: 28),
              Text('Tips', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              const Text('• Phone and computer must both reach the same Wamu server'),
              const Text('• Prefer the QR — fewer typos'),
              const Text('• After linking the server, sign in with OTP or Scan to sign in'),
            ],
          ),
        ),
      ),
    );
  }
}
