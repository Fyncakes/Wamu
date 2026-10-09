import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../shared/models/business_model.dart';
import '../../shared/models/product_model.dart';
import '../../shared/utils/ugx_formatter.dart';
import '../home/catalog_repository.dart';

/// Search tab — businesses + products from GET /search.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _controller = TextEditingController();
  List<BusinessModel> _businesses = [];
  List<ProductModel> _products = [];
  bool _loading = false;
  String? _error;
  bool _searched = false;

  Future<void> _search(String query) async {
    if (query.trim().isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
      _searched = true;
    });
    try {
      final result = await ref.read(catalogRepositoryProvider).search(query.trim());
      setState(() {
        _businesses = result.businesses;
        _products = result.products;
      });
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          decoration: const InputDecoration(
            hintText: 'Search cakes, phones, plumbers…',
            border: InputBorder.none,
          ),
          textInputAction: TextInputAction.search,
          onSubmitted: _search,
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () => _search(_controller.text),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!))
              : !_searched
                  ? const Center(child: Text('Try “cake”, “phones”, or “Ntinda”'))
                  : _businesses.isEmpty && _products.isEmpty
                      ? const Center(child: Text('No results in WAMU catalog'))
                      : ListView(
                          padding: const EdgeInsets.all(16),
                          children: [
                            if (_businesses.isNotEmpty) ...[
                              Text('Businesses', style: Theme.of(context).textTheme.titleLarge),
                              const SizedBox(height: 8),
                              ..._businesses.map(
                                (b) => ListTile(
                                  title: Text(b.name),
                                  subtitle: Text(b.address ?? b.city ?? 'Kampala'),
                                  trailing: b.isVerified
                                      ? Icon(Icons.verified,
                                          color: Theme.of(context).colorScheme.primary)
                                      : null,
                                  onTap: () => context.push('/business/${b.id}'),
                                ),
                              ),
                              const SizedBox(height: 16),
                            ],
                            if (_products.isNotEmpty) ...[
                              Text('Products', style: Theme.of(context).textTheme.titleLarge),
                              const SizedBox(height: 8),
                              ..._products.map(
                                (p) => ListTile(
                                  title: Text(p.name),
                                  subtitle: Text(formatUgx(p.price)),
                                  onTap: () => context.push('/product/${p.id}'),
                                ),
                              ),
                            ],
                          ],
                        ),
    );
  }
}
