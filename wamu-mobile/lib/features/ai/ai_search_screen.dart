import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../shared/utils/json_numbers.dart';
import '../../shared/utils/ugx_formatter.dart';
import 'ai_repository.dart';

/// Level-1 AI assistant — structured businesses/products from WAMU DB only.
class AiSearchScreen extends ConsumerStatefulWidget {
  const AiSearchScreen({super.key, this.initialQuery});

  final String? initialQuery;

  @override
  ConsumerState<AiSearchScreen> createState() => _AiSearchScreenState();
}

class _AiSearchScreenState extends ConsumerState<AiSearchScreen> {
  final _controller = TextEditingController();
  Map<String, dynamic>? _result;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final q = widget.initialQuery?.trim();
    if (q != null && q.isNotEmpty) {
      _controller.text = q;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _search();
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _controller.text.trim();
    if (query.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await ref.read(aiRepositoryProvider).search(query);
      setState(() => _result = result);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final businesses = (_result?['businesses'] as List?) ?? [];
    final products = (_result?['products'] as List?) ?? [];
    final interpretation = _result?['interpretation']?.toString();

    return Scaffold(
      appBar: AppBar(title: const Text('Ask Wamu')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Ask in plain English. Wamu only returns real listings from our catalog.',
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              maxLines: 2,
              decoration: const InputDecoration(
                hintText: 'e.g. Find cakes near Ntinda',
              ),
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _search(),
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: _loading ? null : _search,
              icon: _loading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.auto_awesome),
              label: const Text('Ask Wamu'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            if (_result != null) ...[
              const SizedBox(height: 16),
              if (interpretation != null)
                Text(interpretation, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 12),
              Expanded(
                child: ListView(
                  children: [
                    if (businesses.isNotEmpty) ...[
                      Text('Businesses', style: Theme.of(context).textTheme.titleLarge),
                      ...businesses.map((raw) {
                        final b = raw as Map<String, dynamic>;
                        return ListTile(
                          title: Text(b['name']?.toString() ?? 'Business'),
                          subtitle: Text(b['description']?.toString() ?? ''),
                          onTap: () => context.push('/business/${b['id']}'),
                        );
                      }),
                    ],
                    if (products.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text('Products', style: Theme.of(context).textTheme.titleLarge),
                      ...products.map((raw) {
                        final p = raw as Map<String, dynamic>;
                        final price = parseDoubleOrZero(p['price']);
                        return ListTile(
                          title: Text(p['name']?.toString() ?? 'Product'),
                          subtitle: Text(formatUgx(price)),
                          onTap: () => context.push('/product/${p['id']}'),
                        );
                      }),
                    ],
                    if (businesses.isEmpty && products.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Text('No matching listings in the catalog.'),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
