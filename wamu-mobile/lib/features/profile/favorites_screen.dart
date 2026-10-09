import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../shared/models/business_model.dart';
import '../../shared/widgets/error_view.dart';
import '../../shared/widgets/loading_view.dart';
import '../../shared/widgets/wamu_network_image.dart';
import '../home/catalog_repository.dart';

/// Full-screen favorites list (Profile → Saved businesses).
class FavoritesScreen extends ConsumerStatefulWidget {
  const FavoritesScreen({super.key});

  @override
  ConsumerState<FavoritesScreen> createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends ConsumerState<FavoritesScreen> {
  late Future<List<BusinessModel>> _future;

  @override
  void initState() {
    super.initState();
    _future = ref.read(catalogRepositoryProvider).getFavorites();
  }

  void _reload() {
    setState(() {
      _future = ref.read(catalogRepositoryProvider).getFavorites();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Saved businesses')),
      body: FutureBuilder<List<BusinessModel>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const LoadingView();
          }
          if (snapshot.hasError) {
            return ErrorView(message: '${snapshot.error}', onRetry: _reload);
          }
          final favs = snapshot.data ?? [];
          if (favs.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'No saved businesses yet.\nTap the heart on a storefront.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: favs.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final b = favs[index];
                return ListTile(
                  leading: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(
                      width: 48,
                      height: 48,
                      child: WamuNetworkImage(imageUrl: b.imageUrl),
                    ),
                  ),
                  title: Text(b.name),
                  subtitle: Text(
                    [
                      if (b.city != null) b.city!,
                      if (b.rating != null) '★ ${b.rating!.toStringAsFixed(1)}',
                    ].join(' · '),
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push('/business/${b.id}'),
                );
              },
            ),
          );
        },
      ),
    );
  }
}
