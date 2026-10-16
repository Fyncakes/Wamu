import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// Callback shape expected by [OrdersRepository.payOrderAndAwait].
typedef MomoOtpCallback = Future<String?> Function({
  required String paymentId,
  required String provider,
  String? mockHint,
  Future<void> Function()? onResend,
});

/// Wire a dialog-based MoMo OTP collector for checkout / retry / chat pay.
MomoOtpCallback momoOtpPrompt(BuildContext context) {
  return ({
    required String paymentId,
    required String provider,
    String? mockHint,
    Future<void> Function()? onResend,
  }) {
    return showMomoOtpDialog(
      context,
      provider: provider,
      mockHint: mockHint,
      onResend: onResend,
    );
  };
}

/// Collect Wamu MoMo OTP for MTN / Airtel before payment SUCCESS.
Future<String?> showMomoOtpDialog(
  BuildContext context, {
  required String provider,
  String? mockHint,
  Future<void> Function()? onResend,
}) {
  final label = provider.toUpperCase() == 'AIRTEL' ? 'Airtel Money' : 'MTN MoMo';
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _MomoOtpDialog(
      providerLabel: label,
      mockHint: mockHint,
      onResend: onResend,
    ),
  );
}

class _MomoOtpDialog extends StatefulWidget {
  const _MomoOtpDialog({
    required this.providerLabel,
    this.mockHint,
    this.onResend,
  });

  final String providerLabel;
  final String? mockHint;
  final Future<void> Function()? onResend;

  @override
  State<_MomoOtpDialog> createState() => _MomoOtpDialogState();
}

class _MomoOtpDialogState extends State<_MomoOtpDialog> {
  final _controller = TextEditingController();
  bool _busy = false;
  String? _hint;

  @override
  void initState() {
    super.initState();
    _hint = widget.mockHint;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _resend() async {
    if (widget.onResend == null || _busy) return;
    setState(() => _busy = true);
    try {
      await widget.onResend!();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('MoMo code resent')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _submit() {
    final code = _controller.text.trim();
    if (code.length < 4) return;
    Navigator.of(context).pop(code);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppTheme.messengerSurface,
      title: Text('Confirm ${widget.providerLabel}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Enter the Wamu MoMo code to approve this payment.',
            style: TextStyle(color: AppTheme.messengerMuted),
          ),
          if (_hint != null && _hint!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              'Demo code: $_hint',
              style: const TextStyle(
                color: AppTheme.accentGreen,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            autofocus: true,
            keyboardType: TextInputType.number,
            maxLength: 6,
            textAlign: TextAlign.center,
            style: const TextStyle(
              letterSpacing: 8,
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: AppTheme.messengerText,
            ),
            decoration: const InputDecoration(
              labelText: 'MoMo OTP',
              counterText: '',
            ),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        if (widget.onResend != null)
          TextButton(
            onPressed: _busy ? null : _resend,
            child: const Text('Resend'),
          ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: const Text('Confirm pay'),
        ),
      ],
    );
  }
}
