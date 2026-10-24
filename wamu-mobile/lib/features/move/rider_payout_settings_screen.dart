import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/utils/phone_normalize.dart';
import '../../shared/utils/ugx_formatter.dart';
import '../../shared/widgets/loading_view.dart';

/// Rider MoMo destination + recent delivery-fee disbursements.
class RiderPayoutSettingsScreen extends ConsumerStatefulWidget {
  const RiderPayoutSettingsScreen({super.key});

  @override
  ConsumerState<RiderPayoutSettingsScreen> createState() =>
      _RiderPayoutSettingsScreenState();
}

class _RiderPayoutSettingsScreenState
    extends ConsumerState<RiderPayoutSettingsScreen> {
  final _phone = TextEditingController(text: '+256');
  String _provider = 'MTN';
  List<Map<String, dynamic>> _payouts = [];
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _phone.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final client = ref.read(apiClientProvider);
      final earnings = await client.get('/dashboard/riders/me/earnings');
      final d = Map<String, dynamic>.from(earnings.data as Map);
      final phone = (d['payout_phone']?.toString().isNotEmpty == true)
          ? d['payout_phone'].toString()
          : '+256';
      final provider = (d['payout_provider']?.toString() ?? 'MTN').toUpperCase();
      List<Map<String, dynamic>> payouts = [];
      try {
        final res = await client.get('/riders/me/payouts');
        if (res.data is List) {
          payouts = (res.data as List).cast<Map<String, dynamic>>();
        }
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _phone.text = phone;
        _provider = {'MTN', 'AIRTEL', 'MOCK'}.contains(provider) ? provider : 'MTN';
        _payouts = payouts;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _save() async {
    String phone;
    try {
      phone = normalizeUgPhone(_phone.text);
    } catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a valid +256 MoMo number')),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      await ref.read(apiClientProvider).patch('/riders/me/payout', data: {
        'payout_phone': phone,
        'payout_provider': _provider,
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Payout destination saved')),
      );
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text('Rider payouts')),
      body: _loading
          ? LoadingView()
          : ListView(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                if (_error != null)
                  Padding(
                    padding: EdgeInsets.only(bottom: 12),
                    child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                  ),
                Text(
                  'Delivery fees are sent to this number after you complete a job.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: AppTheme.muted(context),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _phone,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: 'Payout phone (MoMo / Airtel)',
                    hintText: '+2567…',
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: _provider,
                  decoration: const InputDecoration(labelText: 'Payout rail'),
                  items: const [
                    DropdownMenuItem(value: 'MTN', child: Text('MTN MoMo')),
                    DropdownMenuItem(value: 'AIRTEL', child: Text('Airtel Money')),
                    DropdownMenuItem(value: 'MOCK', child: Text('Test payment')),
                  ],
                  onChanged: _saving
                      ? null
                      : (v) {
                          if (v != null) setState(() => _provider = v);
                        },
                ),
                SizedBox(height: 20),
                ElevatedButton(
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Text('Save payout destination'),
                ),
                SizedBox(height: 28),
                Text('Recent fee payouts', style: theme.textTheme.titleMedium),
                SizedBox(height: 8),
                if (_payouts.isEmpty)
                  Text(
                    'No fee payouts yet — they appear after delivered jobs.',
                    style: TextStyle(color: AppTheme.muted(context)),
                  )
                else
                  ..._payouts.take(20).map((p) {
                    final status = p['status']?.toString() ?? '—';
                    final statusLabel = switch (status) {
                      'PENDING' => 'Queued',
                      'PROCESSING' => 'Sending…',
                      'SUCCESS' => 'Sent',
                      'FAILED' => 'Failed',
                      _ => status,
                    };
                    final amount = p['amount'];
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        amount != null
                            ? formatUgx(double.tryParse('$amount') ?? 0)
                            : 'Payout',
                      ),
                      subtitle: Text(
                        [
                          statusLabel,
                          p['payee_phone']?.toString() ?? '',
                        ].where((s) => s.isNotEmpty).join(' · '),
                      ),
                    );
                  }),
              ],
            ),
    );
  }
}
