import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/files/save_download.dart';
import '../../core/network/api_client.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/utils/ugx_formatter.dart';
import '../../shared/widgets/error_view.dart';
import '../../shared/widgets/loading_view.dart';

/// Merchant home — answers: sold? earned? what needs attention?
class MerchantDashboardScreen extends ConsumerStatefulWidget {
  const MerchantDashboardScreen({super.key});

  @override
  ConsumerState<MerchantDashboardScreen> createState() =>
      _MerchantDashboardScreenState();
}

class _MerchantDashboardScreenState extends ConsumerState<MerchantDashboardScreen> {
  late Future<Map<String, dynamic>> _future;
  String _period = '30d';
  String? _businessId;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<Map<String, dynamic>> _load() async {
    final client = ref.read(apiClientProvider);
    final overview = await client.get('/dashboard/business/overview');
    final d = Map<String, dynamic>.from(overview.data as Map);
    final bizId = d['business_id']?.toString();
    _businessId = bizId;
    if (bizId == null || bizId.isEmpty) return d;
    final dash = await client.get(
      '/businesses/$bizId/finance/dashboard',
      queryParameters: {'period': _period},
    );
    d['dashboard'] = Map<String, dynamic>.from(dash.data as Map);
    return d;
  }

  void _setPeriod(String p) {
    setState(() {
      _period = p;
      _future = _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Business dashboard'),
        actions: [
          IconButton(
            tooltip: 'Reports',
            icon: const Icon(Icons.download_outlined),
            onPressed: () {
              final id = _businessId;
              if (id == null) return;
              context.push('/business-owner/reports?businessId=$id');
            },
          ),
        ],
      ),
      body: FutureBuilder(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const LoadingView();
          }
          if (snap.hasError) {
            return ErrorView(
              message: '${snap.error}',
              onRetry: () => setState(() => _future = _load()),
            );
          }
          final d = snap.data!;
          final dash = d['dashboard'] is Map
              ? Map<String, dynamic>.from(d['dashboard'] as Map)
              : <String, dynamic>{};
          final name = dash['business_name']?.toString() ??
              d['name']?.toString() ??
              'Your shop';
          final sales = (dash['total_sales_minor'] as num?)?.toDouble() ?? 0;
          final net = (dash['net_earnings_minor'] as num?)?.toDouble() ?? 0;
          final orders = dash['orders_total'] as int? ?? 0;
          final pending = dash['pending_action_count'] as int? ?? 0;
          final settled = (dash['settled_minor'] as num?)?.toDouble() ?? 0;
          final outstanding =
              (dash['outstanding_minor'] as num?)?.toDouble() ?? 0;
          final commission =
              (dash['commission_minor'] as num?)?.toDouble() ?? 0;
          final refunds = (dash['refunds_minor'] as num?)?.toDouble() ?? 0;
          final byStatus =
              Map<String, dynamic>.from(dash['orders_by_status'] as Map? ?? {});
          final trend = (dash['sales_trend'] as List? ?? [])
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList();
          final attention = (dash['attention'] as List? ?? [])
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList();

          return RefreshIndicator(
            onRefresh: () async => setState(() => _future = _load()),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                Text(name, style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                )),
                const SizedBox(height: 4),
                Text(
                  'Live figures from your Wamu records · not demo data',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppTheme.messengerMuted,
                  ),
                ),
                const SizedBox(height: 12),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: '7d', label: Text('7d')),
                    ButtonSegment(value: '30d', label: Text('30d')),
                    ButtonSegment(value: '90d', label: Text('90d')),
                  ],
                  selected: {_period},
                  onSelectionChanged: (s) => _setPeriod(s.first),
                ),
                const SizedBox(height: 16),
                Text(
                  'At a glance',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: _KpiCard(
                        label: 'Total sales',
                        value: formatUgx(sales),
                        hint: 'Paid successfully',
                        emphasize: true,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _KpiCard(
                        label: 'Net earnings',
                        value: formatUgx(net),
                        hint: 'After fees & refunds',
                        emphasize: true,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: _KpiCard(
                        label: 'Orders',
                        value: '$orders',
                        hint: byStatus.entries
                            .take(3)
                            .map((e) => '${e.key}: ${e.value}')
                            .join(' · '),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _KpiCard(
                        label: 'Needs you',
                        value: '$pending',
                        hint: 'Awaiting action',
                        alert: pending > 0,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                _BreakdownRow(
                  settled: settled,
                  outstanding: outstanding,
                  commission: commission,
                  refunds: refunds,
                ),
                const SizedBox(height: 22),
                Text(
                  'Sales trend',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                _SalesTrendChart(points: trend),
                const SizedBox(height: 22),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Needs attention',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () => context.push('/business-owner/orders'),
                      child: const Text('All orders'),
                    ),
                  ],
                ),
                if (attention.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      'No orders waiting on you right now.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: AppTheme.messengerMuted,
                      ),
                    ),
                  )
                else
                  ...attention.map((o) {
                    final total =
                        (o['total_minor'] as num?)?.toDouble() ?? 0;
                    final created = o['created_at']?.toString();
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: CircleAvatar(
                        backgroundColor:
                            AppTheme.accentGreen.withValues(alpha: 0.15),
                        child: Text(
                          (o['status']?.toString() ?? '?').substring(0, 1),
                          style: const TextStyle(
                            color: AppTheme.primaryGreen,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      title: Text(
                        formatUgx(total),
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      subtitle: Text(
                        [
                          o['status']?.toString() ?? '',
                          if (created != null)
                            created.split('T').first,
                        ].where((s) => s.isNotEmpty).join(' · '),
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => context.push('/business-owner/orders'),
                    );
                  }),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: () {
                    final id = _businessId;
                    if (id == null) return;
                    context.push('/business-owner/reports?businessId=$id');
                  },
                  icon: const Icon(Icons.assessment_outlined),
                  label: const Text('Download reports'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _KpiCard extends StatelessWidget {
  const _KpiCard({
    required this.label,
    required this.value,
    this.hint,
    this.emphasize = false,
    this.alert = false,
  });

  final String label;
  final String value;
  final String? hint;
  final bool emphasize;
  final bool alert;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: alert
            ? AppTheme.errorRed.withValues(alpha: 0.08)
            : theme.colorScheme.surfaceContainerHighest,
        border: emphasize
            ? Border.all(color: AppTheme.accentGreen.withValues(alpha: 0.35))
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.bodySmall),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: emphasize ? 18 : 16,
              color: alert ? AppTheme.errorRed : null,
            ),
          ),
          if (hint != null && hint!.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              hint!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppTheme.messengerMuted,
                fontSize: 11,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _BreakdownRow extends StatelessWidget {
  const _BreakdownRow({
    required this.settled,
    required this.outstanding,
    required this.commission,
    required this.refunds,
  });

  final double settled;
  final double outstanding;
  final double commission;
  final double refunds;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.dividerColor.withValues(alpha: 0.4)),
      ),
      child: Column(
        children: [
          _line(theme, 'Settled this period', formatUgx(settled)),
          _line(theme, 'Still owed (all time)', formatUgx(outstanding)),
          _line(theme, 'Platform fee (2.5%)', formatUgx(commission)),
          _line(theme, 'Refunds this period', formatUgx(refunds), last: true),
        ],
      ),
    );
  }

  Widget _line(ThemeData theme, String k, String v, {bool last = false}) {
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : 6),
      child: Row(
        children: [
          Expanded(child: Text(k, style: theme.textTheme.bodySmall)),
          Text(v, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _SalesTrendChart extends StatelessWidget {
  const _SalesTrendChart({required this.points});

  final List<Map<String, dynamic>> points;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (points.isEmpty) {
      return Container(
        height: 140,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: theme.colorScheme.surfaceContainerHighest,
        ),
        child: Text(
          'No successful payments in this period yet',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: AppTheme.messengerMuted,
          ),
        ),
      );
    }
    final values =
        points.map((p) => (p['sales_minor'] as num?)?.toDouble() ?? 0).toList();
    final maxV = values.fold<double>(0, (a, b) => a > b ? a : b);
    final show = points.length > 14 ? points.sublist(points.length - 14) : points;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 140,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final p in show) ...[
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: FractionallySizedBox(
                      heightFactor: maxV <= 0
                          ? 0.05
                          : (((p['sales_minor'] as num?)?.toDouble() ?? 0) / maxV)
                              .clamp(0.05, 1.0),
                      alignment: Alignment.bottomCenter,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: AppTheme.accentGreen,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '${show.first['period']} → ${show.last['period']} · UGX',
          style: theme.textTheme.bodySmall?.copyWith(
            color: AppTheme.messengerMuted,
          ),
        ),
      ],
    );
  }
}

/// Downloadable reports hub — sales, orders, earnings, payments, products, deliveries.
class MerchantReportsScreen extends ConsumerStatefulWidget {
  const MerchantReportsScreen({super.key, this.businessId});

  final String? businessId;

  @override
  ConsumerState<MerchantReportsScreen> createState() =>
      _MerchantReportsScreenState();
}

class _MerchantReportsScreenState extends ConsumerState<MerchantReportsScreen> {
  String? _bizId;
  String _busy = '';
  DateTimeRange? _range;
  String? _error;

  static const _reports = [
    (
      'sales',
      'Sales report',
      'Paid collections, amounts, and MoMo references',
    ),
    (
      'orders',
      'Orders report',
      'Order IDs, products, status, and totals',
    ),
    (
      'earnings',
      'Earnings breakdown',
      'Gross, fees, refunds, net, and settlements',
    ),
    (
      'payments',
      'Payments report',
      'MTN / Airtel status, references, refunds',
    ),
    (
      'products',
      'Products report',
      'Best sellers, quantities, stock',
    ),
    (
      'deliveries',
      'Delivery report',
      'Fees, riders, and delivery status',
    ),
  ];

  @override
  void initState() {
    super.initState();
    _bizId = widget.businessId;
    _resolveBiz();
  }

  Future<void> _resolveBiz() async {
    if (_bizId != null && _bizId!.isNotEmpty) return;
    try {
      final res =
          await ref.read(apiClientProvider).get('/dashboard/business/overview');
      final id = (res.data as Map)['business_id']?.toString();
      if (mounted) setState(() => _bizId = id);
    } catch (_) {}
  }

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 2),
      lastDate: now,
      initialDateRange: _range ??
          DateTimeRange(start: now.subtract(const Duration(days: 30)), end: now),
    );
    if (picked != null) setState(() => _range = picked);
  }

  Future<void> _download(String type, String format) async {
    final id = _bizId;
    if (id == null) return;
    setState(() {
      _busy = '$type-$format';
      _error = null;
    });
    try {
      final qp = <String, dynamic>{
        'report_type': type,
        'format': format,
      };
      if (_range != null) {
        qp['date_from'] = _range!.start.toUtc().toIso8601String();
        qp['date_to'] = _range!.end.toUtc().toIso8601String();
      }
      final client = ref.read(apiClientProvider);
      final res = await client.dio.get<List<int>>(
        '/businesses/$id/finance/reports',
        queryParameters: qp,
        options: Options(responseType: ResponseType.bytes),
      );
      final bytes = res.data ?? <int>[];
      final ext = format == 'pdf' ? 'pdf' : 'csv';
      final mime =
          format == 'pdf' ? 'application/pdf' : 'text/csv;charset=utf-8';
      final stamp = DateFormat('yyyyMMdd').format(DateTime.now());
      final filename = 'wamu-$type-$stamp.$ext';
      await saveAndShareBytes(
        bytes: bytes,
        filename: filename,
        mimeType: mime,
        subject: 'Wamu $type report',
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Saved $filename')),
        );
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = '');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rangeLabel = _range == null
        ? 'All time (or pick dates)'
        : '${DateFormat.yMMMd().format(_range!.start)} – ${DateFormat.yMMMd().format(_range!.end)}';

    return Scaffold(
      appBar: AppBar(title: const Text('Reports')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          Text(
            'Download CSV (Excel) or PDF. Figures match your live ledger and payments.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: AppTheme.messengerMuted,
            ),
          ),
          const SizedBox(height: 12),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.date_range, color: AppTheme.accentGreen),
            title: const Text('Date range'),
            subtitle: Text(rangeLabel),
            trailing: TextButton(onPressed: _pickRange, child: const Text('Change')),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ),
          const SizedBox(height: 8),
          for (final r in _reports) ...[
            Card(
              margin: const EdgeInsets.only(bottom: 10),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(r.$2, style: const TextStyle(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 4),
                    Text(
                      r.$3,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: AppTheme.messengerMuted,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        OutlinedButton(
                          onPressed: _busy.isNotEmpty
                              ? null
                              : () => _download(r.$1, 'csv'),
                          child: Text(
                            _busy == '${r.$1}-csv' ? '…' : 'CSV',
                          ),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton(
                          onPressed: _busy.isNotEmpty
                              ? null
                              : () => _download(r.$1, 'pdf'),
                          child: Text(
                            _busy == '${r.$1}-pdf' ? '…' : 'PDF',
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
