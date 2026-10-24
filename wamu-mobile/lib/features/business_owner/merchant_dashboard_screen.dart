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
              padding: EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                Text(name, style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                )),
                SizedBox(height: 4),
                Text(
                  'Live figures from your Wamu records · not demo data',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppTheme.muted(context),
                  ),
                ),
                SizedBox(height: 12),
                SegmentedButton<String>(
                  segments: [
                    ButtonSegment(value: '7d', label: Text('7d')),
                    ButtonSegment(value: '30d', label: Text('30d')),
                    ButtonSegment(value: '90d', label: Text('90d')),
                  ],
                  selected: {_period},
                  onSelectionChanged: (s) => _setPeriod(s.first),
                ),
                SizedBox(height: 16),
                Text(
                  'At a glance',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                SizedBox(height: 8),
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
                    SizedBox(width: 10),
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
                SizedBox(height: 10),
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
                    SizedBox(width: 10),
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
                SizedBox(height: 10),
                _BreakdownRow(
                  settled: settled,
                  outstanding: outstanding,
                  commission: commission,
                  refunds: refunds,
                ),
                SizedBox(height: 22),
                _SalesTrendChart(
                  points: trend,
                  period: _period,
                  dateFrom: dash['date_from']?.toString(),
                  dateTo: dash['date_to']?.toString(),
                  totalSalesMinor: sales,
                ),
                SizedBox(height: 22),
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
                      child: Text('All orders'),
                    ),
                  ],
                ),
                if (attention.isEmpty)
                  Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      'No orders waiting on you right now.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: AppTheme.muted(context),
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
      padding: EdgeInsets.all(14),
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
          SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: emphasize ? 18 : 16,
              color: alert ? AppTheme.errorRed : null,
            ),
          ),
          if (hint != null && hint!.isNotEmpty) ...[
            SizedBox(height: 4),
            Text(
              hint!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppTheme.muted(context),
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

/// Daily sales accountability chart (Shopify/Apple-style: one colour, axes,
/// tap for exact day, plain-language summary).
class _SalesTrendChart extends StatefulWidget {
  const _SalesTrendChart({
    required this.points,
    required this.period,
    required this.totalSalesMinor,
    this.dateFrom,
    this.dateTo,
  });

  final List<Map<String, dynamic>> points;
  final String period;
  final double totalSalesMinor;
  final String? dateFrom;
  final String? dateTo;

  @override
  State<_SalesTrendChart> createState() => _SalesTrendChartState();
}

class _SalesTrendChartState extends State<_SalesTrendChart> {
  int? _selected;

  static String _compactUgx(num amount) {
    final v = amount.abs();
    if (v >= 1000000) {
      final m = v / 1000000;
      return 'UGX ${m >= 10 ? m.toStringAsFixed(0) : m.toStringAsFixed(1)}M';
    }
    if (v >= 1000) {
      final k = v / 1000;
      return 'UGX ${k >= 100 ? k.toStringAsFixed(0) : k.toStringAsFixed(1)}k';
    }
    return formatUgx(amount);
  }

  static DateTime? _parseDay(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      return DateTime.parse(raw.split('T').first).toLocal();
    } catch (_) {
      return null;
    }
  }

  static String _dayLabel(DateTime d, {required bool withMonth}) {
    if (withMonth) {
      return DateFormat('d MMM').format(d);
    }
    return DateFormat('d').format(d);
  }

  static String _weekdayShort(DateTime d) => DateFormat('EEE').format(d);

  /// Fill every calendar day in the period (zeros included) so empty days
  /// are visible — critical for accountability.
  List<_TrendDay> _series() {
    final byDay = <String, _TrendDay>{};
    for (final p in widget.points) {
      final period = p['period']?.toString() ?? '';
      final day = _parseDay(period);
      if (day == null) continue;
      final key = DateFormat('yyyy-MM-dd').format(day);
      byDay[key] = _TrendDay(
        date: DateTime(day.year, day.month, day.day),
        salesMinor: (p['sales_minor'] as num?)?.toDouble() ?? 0,
        orders: (p['orders'] as num?)?.toInt() ?? 0,
      );
    }

    var start = _parseDay(widget.dateFrom);
    var end = _parseDay(widget.dateTo);
    if (start == null || end == null) {
      if (byDay.isEmpty) return const [];
      final sorted = byDay.keys.toList()..sort();
      start = DateTime.parse(sorted.first);
      end = DateTime.parse(sorted.last);
    }
    start = DateTime(start.year, start.month, start.day);
    end = DateTime(end.year, end.month, end.day);
    if (end.isBefore(start)) return const [];

    final days = <_TrendDay>[];
    for (var d = start; !d.isAfter(end); d = d.add(const Duration(days: 1))) {
      final key = DateFormat('yyyy-MM-dd').format(d);
      days.add(
        byDay[key] ??
            _TrendDay(date: d, salesMinor: 0, orders: 0),
      );
    }

    // Shopify: bars for < ~30 points; bucket to weeks for longer ranges.
    if (days.length > 31) {
      return _bucketWeeks(days);
    }
    return days;
  }

  List<_TrendDay> _bucketWeeks(List<_TrendDay> days) {
    final buckets = <_TrendDay>[];
    for (var i = 0; i < days.length; i += 7) {
      final chunk = days.sublist(i, (i + 7).clamp(0, days.length));
      final sales = chunk.fold<double>(0, (a, b) => a + b.salesMinor);
      final orders = chunk.fold<int>(0, (a, b) => a + b.orders);
      buckets.add(
        _TrendDay(
          date: chunk.first.date,
          salesMinor: sales,
          orders: orders,
          weekEnd: chunk.last.date,
        ),
      );
    }
    return buckets;
  }

  @override
  void didUpdateWidget(covariant _SalesTrendChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.period != widget.period ||
        oldWidget.points != widget.points) {
      _selected = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final series = _series();
    final isWeekly = series.any((d) => d.weekEnd != null);
    final periodLabel = switch (widget.period) {
      '7d' => 'Last 7 days',
      '90d' => 'Last 90 days',
      _ => 'Last 30 days',
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          isWeekly ? 'Weekly sales' : 'Daily sales',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        SizedBox(height: 2),
        Text(
          isWeekly
              ? 'Money collected each week (successful payments only)'
              : 'Money collected each day (successful payments only)',
          style: theme.textTheme.bodySmall?.copyWith(
            color: AppTheme.muted(context),
          ),
        ),
        SizedBox(height: 10),
        if (series.isEmpty || series.every((d) => d.salesMinor <= 0))
          Container(
            height: 160,
            alignment: Alignment.center,
            padding: EdgeInsets.all(16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: theme.colorScheme.surfaceContainerHighest,
            ),
            child: Text(
              'No successful payments in $periodLabel yet.\n'
              'When customers pay, each ${isWeekly ? 'week' : 'day'} '
              'will show here in UGX.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: AppTheme.muted(context),
              ),
            ),
          )
        else ...[
          _InsightStrip(series: series, isWeekly: isWeekly),
          const SizedBox(height: 12),
          _LabeledBarChart(
            series: series,
            isWeekly: isWeekly,
            selected: _selected,
            onSelect: (i) => setState(() {
              _selected = _selected == i ? null : i;
            }),
            compactUgx: _compactUgx,
            dayLabel: _dayLabel,
          ),
          if (_selected != null &&
              _selected! >= 0 &&
              _selected! < series.length) ...[
            SizedBox(height: 10),
            _DayDetailCard(
              day: series[_selected!],
              isWeekly: isWeekly,
              weekdayShort: _weekdayShort,
              dayLabel: _dayLabel,
            ),
          ] else ...[
            SizedBox(height: 8),
            Text(
              'Tap a bar to see that ${isWeekly ? 'week' : 'day'}’s amount',
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppTheme.muted(context),
              ),
            ),
          ],
          SizedBox(height: 6),
          Text(
            '$periodLabel · total ${formatUgx(widget.totalSalesMinor)}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: AppTheme.muted(context),
            ),
          ),
        ],
      ],
    );
  }
}

class _TrendDay {
  const _TrendDay({
    required this.date,
    required this.salesMinor,
    required this.orders,
    this.weekEnd,
  });

  final DateTime date;
  final double salesMinor;
  final int orders;
  final DateTime? weekEnd;
}

class _InsightStrip extends StatelessWidget {
  const _InsightStrip({required this.series, required this.isWeekly});

  final List<_TrendDay> series;
  final bool isWeekly;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final withSales = series.where((d) => d.salesMinor > 0).toList();
    if (withSales.isEmpty) return const SizedBox.shrink();

    _TrendDay best = withSales.first;
    for (final d in withSales) {
      if (d.salesMinor > best.salesMinor) best = d;
    }
    final total =
        series.fold<double>(0, (a, b) => a + b.salesMinor);
    final avg = total / series.length;
    final active = withSales.length;

    String bestLabel;
    if (isWeekly && best.weekEnd != null) {
      bestLabel =
          '${DateFormat('d MMM').format(best.date)}–${DateFormat('d MMM').format(best.weekEnd!)}';
    } else {
      bestLabel = DateFormat('EEE d MMM').format(best.date);
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.dividerColor.withValues(alpha: 0.4)),
      ),
      child: Column(
        children: [
          _insightRow(
            theme,
            'Best ${isWeekly ? 'week' : 'day'}',
            '$bestLabel · ${formatUgx(best.salesMinor)}',
          ),
          _insightRow(
            theme,
            'Average / ${isWeekly ? 'week' : 'day'}',
            formatUgx(avg),
          ),
          _insightRow(
            theme,
            isWeekly ? 'Weeks with sales' : 'Days with sales',
            '$active of ${series.length}',
            last: true,
          ),
        ],
      ),
    );
  }

  Widget _insightRow(ThemeData theme, String k, String v, {bool last = false}) {
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 118,
            child: Text(k, style: theme.textTheme.bodySmall),
          ),
          Expanded(
            child: Text(
              v,
              textAlign: TextAlign.end,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

class _LabeledBarChart extends StatelessWidget {
  const _LabeledBarChart({
    required this.series,
    required this.isWeekly,
    required this.selected,
    required this.onSelect,
    required this.compactUgx,
    required this.dayLabel,
  });

  final List<_TrendDay> series;
  final bool isWeekly;
  final int? selected;
  final ValueChanged<int> onSelect;
  final String Function(num) compactUgx;
  final String Function(DateTime, {required bool withMonth}) dayLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final maxV =
        series.fold<double>(0, (a, b) => a > b.salesMinor ? a : b.salesMinor);
    final midV = maxV / 2;
    // Label every nth tick so X-axis stays readable on mobile.
    final labelEvery = series.length <= 7
        ? 1
        : series.length <= 14
            ? 2
            : series.length <= 21
                ? 3
                : 5;

    return Container(
      padding: EdgeInsets.fromLTRB(4, 12, 8, 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: theme.colorScheme.surfaceContainerHighest,
      ),
      child: Column(
        children: [
          SizedBox(
            height: 168,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Y-axis (Shopify: labels outside the data area)
                SizedBox(
                  width: 52,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        compactUgx(maxV),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: AppTheme.muted(context),
                          fontSize: 10,
                        ),
                      ),
                      Text(
                        compactUgx(midV),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: AppTheme.muted(context),
                          fontSize: 10,
                        ),
                      ),
                      Text(
                        '0',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: AppTheme.muted(context),
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: List.generate(3, (_) {
                            return Container(
                              height: 1,
                              color: theme.dividerColor.withValues(alpha: 0.35),
                            );
                          }),
                        ),
                      ),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          for (var i = 0; i < series.length; i++)
                            Expanded(
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () => onSelect(i),
                                child: Padding(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: series.length > 20 ? 1 : 2.5,
                                  ),
                                  child: Align(
                                    alignment: Alignment.bottomCenter,
                                    child: FractionallySizedBox(
                                      heightFactor: maxV <= 0
                                          ? 0
                                          : (series[i].salesMinor / maxV).clamp(
                                              series[i].salesMinor > 0
                                                  ? 0.04
                                                  : 0.0,
                                              1.0,
                                            ),
                                      widthFactor: 0.72,
                                      child: AnimatedContainer(
                                        duration:
                                            const Duration(milliseconds: 180),
                                        decoration: BoxDecoration(
                                          color: selected == i
                                              ? AppTheme.primaryGreen
                                              : AppTheme.accentGreen.withValues(
                                                  alpha: series[i].salesMinor > 0
                                                      ? 0.9
                                                      : 0.18,
                                                ),
                                          borderRadius:
                                              BorderRadius.circular(4),
                                          border: selected == i
                                              ? Border.all(
                                                  color: Colors.white
                                                      .withValues(alpha: 0.55),
                                                  width: 1.5,
                                                )
                                              : null,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          // X-axis date labels
          Row(
            children: [
              const SizedBox(width: 58),
              Expanded(
                child: Row(
                  children: [
                    for (var i = 0; i < series.length; i++)
                      Expanded(
                        child: (i % labelEvery == 0 || i == series.length - 1)
                            ? Text(
                                dayLabel(
                                  series[i].date,
                                  withMonth: series.length <= 10 ||
                                      i == 0 ||
                                      i == series.length - 1,
                                ),
                                textAlign: TextAlign.center,
                                maxLines: 1,
                                overflow: TextOverflow.clip,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: AppTheme.muted(context),
                                  fontSize: 9,
                                ),
                              )
                            : const SizedBox.shrink(),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DayDetailCard extends StatelessWidget {
  const _DayDetailCard({
    required this.day,
    required this.isWeekly,
    required this.weekdayShort,
    required this.dayLabel,
  });

  final _TrendDay day;
  final bool isWeekly;
  final String Function(DateTime) weekdayShort;
  final String Function(DateTime, {required bool withMonth}) dayLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = isWeekly && day.weekEnd != null
        ? '${dayLabel(day.date, withMonth: true)} – '
            '${dayLabel(day.weekEnd!, withMonth: true)}'
        : '${weekdayShort(day.date)}, ${dayLabel(day.date, withMonth: true)}';

    return Container(
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: AppTheme.accentGreen.withValues(alpha: 0.12),
        border: Border.all(
          color: AppTheme.accentGreen.withValues(alpha: 0.35),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppTheme.muted(context),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  formatUgx(day.salesMinor),
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 18,
                  ),
                ),
              ],
            ),
          ),
          Text(
            day.orders == 1 ? '1 order' : '${day.orders} orders',
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
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
      appBar: AppBar(title: Text('Reports')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          Text(
            'Download CSV (Excel) or PDF. Figures match your live ledger and payments.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: AppTheme.muted(context),
            ),
          ),
          SizedBox(height: 12),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.date_range, color: AppTheme.accentGreen),
            title: Text('Date range'),
            subtitle: Text(rangeLabel),
            trailing: TextButton(onPressed: _pickRange, child: Text('Change')),
          ),
          if (_error != null)
            Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ),
          SizedBox(height: 8),
          for (final r in _reports) ...[
            Card(
              margin: EdgeInsets.only(bottom: 10),
              child: Padding(
                padding: EdgeInsets.fromLTRB(14, 12, 14, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(r.$2, style: TextStyle(fontWeight: FontWeight.w800)),
                    SizedBox(height: 4),
                    Text(
                      r.$3,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: AppTheme.muted(context),
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
