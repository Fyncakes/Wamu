import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/models/business_model.dart';
import '../../shared/utils/phone_normalize.dart';
import '../../shared/utils/ugx_formatter.dart';
import '../../shared/widgets/loading_view.dart';

/// Edit MoMo/Airtel payout destination + recent disbursements.
class PayoutSettingsScreen extends ConsumerStatefulWidget {
  const PayoutSettingsScreen({super.key});

  @override
  ConsumerState<PayoutSettingsScreen> createState() => _PayoutSettingsScreenState();
}

class _PayoutSettingsScreenState extends ConsumerState<PayoutSettingsScreen> {
  final _payoutPhone = TextEditingController(text: '+256');
  BusinessModel? _biz;
  List<Map<String, dynamic>> _payouts = [];
  String _provider = 'MTN';
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
    _payoutPhone.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final client = ref.read(apiClientProvider);
      final mine = await client.get('/businesses/mine');
      final list = (mine.data as List).cast<Map<String, dynamic>>();
      if (list.isEmpty) {
        setState(() {
          _biz = null;
          _loading = false;
        });
        return;
      }
      final biz = BusinessModel.fromJson(list.first);
      final phone = biz.payoutPhone ?? biz.phone ?? '+256';
      final provider = (biz.payoutProvider ?? 'MTN').toUpperCase();
      List<Map<String, dynamic>> payouts = [];
      try {
        final res = await client.get('/businesses/${biz.id}/payouts');
        if (res.data is List) {
          payouts = (res.data as List).cast<Map<String, dynamic>>();
        }
      } catch (_) {
        // Payout history optional if empty / 403 during setup
      }
      if (!mounted) return;
      setState(() {
        _biz = biz;
        _payoutPhone.text = phone;
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
    final biz = _biz;
    if (biz == null) return;
    String phone;
    try {
      phone = normalizeUgPhone(_payoutPhone.text);
    } catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a valid +256 payout number')),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      await ref.read(apiClientProvider).patch('/businesses/${biz.id}', data: {
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
      appBar: AppBar(title: const Text('Payout settings')),
      body: _loading
          ? const LoadingView()
          : _biz == null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'Create a business first, then set where MoMo payouts should land.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyLarge,
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                  children: [
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                      ),
                    Text(_biz!.name, style: theme.textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(
                      'Disbursements go to this number after a customer pays. '
                      'If empty, Wamu falls back to your business phone.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: AppTheme.messengerMuted,
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _payoutPhone,
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
                    const SizedBox(height: 20),
                    ElevatedButton(
                      onPressed: _saving ? null : _save,
                      child: _saving
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text('Save payout destination'),
                    ),
                    const SizedBox(height: 28),
                    Text('Recent payouts', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 8),
                    if (_payouts.isEmpty)
                      const Text(
                        'No disbursements yet — they’ll show here after paid orders.',
                        style: TextStyle(color: AppTheme.messengerMuted),
                      )
                    else
                      ..._payouts.take(20).map((p) {
                        final net = p['amount'];
                        final fee = p['platform_fee'];
                        final status = p['status']?.toString() ?? '—';
                        final created = p['created_at']?.toString();
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            net != null
                                ? formatUgx(double.tryParse('$net') ?? 0)
                                : 'Payout',
                          ),
                          subtitle: Text(
                            [
                              status,
                              if (fee != null)
                                'fee ${formatUgx(double.tryParse('$fee') ?? 0)}',
                              if (created != null) created.split('T').first,
                            ].join(' · '),
                          ),
                          trailing: Text(
                            p['payee_phone']?.toString() ?? '',
                            style: const TextStyle(fontSize: 12),
                          ),
                        );
                      }),
                  ],
                ),
    );
  }
}
