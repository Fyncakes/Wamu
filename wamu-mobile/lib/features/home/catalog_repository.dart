import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import '../../shared/models/business_model.dart';
import '../../shared/models/category_model.dart';
import '../../shared/models/product_model.dart';
import '../../shared/models/review_model.dart';

/// Marketplace catalog — aligned with FastAPI list/search shapes.
class CatalogRepository {
  CatalogRepository(this._client);

  final ApiClient _client;

  Future<List<CategoryModel>> getCategories() async {
    final response = await _client.get('/categories');
    return _extractList(response.data).map(CategoryModel.fromJson).toList();
  }

  Future<List<BusinessModel>> getBusinesses({
    String? categoryId,
    String? q,
    double? lat,
    double? lng,
    double? radiusKm,
  }) async {
    final response = await _client.get('/businesses', queryParameters: {
      if (categoryId != null) 'category_id': categoryId,
      if (q != null && q.isNotEmpty) 'q': q,
      if (lat != null) 'lat': lat,
      if (lng != null) 'lng': lng,
      if (radiusKm != null) 'radius_km': radiusKm,
    });
    return _extractList(response.data).map(BusinessModel.fromJson).toList();
  }

  Future<BusinessModel> getBusiness(String id) async {
    final response = await _client.get('/businesses/$id');
    final data = response.data as Map<String, dynamic>;
    return BusinessModel.fromJson(data);
  }

  /// Paginated product list. [hasMore] is inferred when a full page returns.
  Future<({List<ProductModel> items, bool hasMore})> getProducts({
    String? businessId,
    int page = 1,
    int pageSize = 20,
  }) async {
    final response = await _client.get('/products', queryParameters: {
      if (businessId != null) 'business_id': businessId,
      'page': page,
      'page_size': pageSize,
    });
    final items = _extractList(response.data)
        .map(ProductModel.fromJson)
        .where((p) => (p.imageUrl ?? '').trim().isNotEmpty)
        .toList();
    return (items: items, hasMore: items.length >= pageSize);
  }

  Future<ProductModel> getProduct(String id) async {
    final response = await _client.get('/products/$id');
    return ProductModel.fromJson(response.data as Map<String, dynamic>);
  }

  /// Similar / recommended rails for product detail discovery.
  Future<({
    List<ProductModel> items,
    List<ProductModel> sameShop,
    List<ProductModel> sameCategory,
    List<ProductModel> popular,
  })> getRelatedProducts(String productId, {int limit = 12}) async {
    final response = await _client.get(
      '/products/$productId/related',
      queryParameters: {'limit': limit},
    );
    final data = response.data;
    if (data is! Map<String, dynamic>) {
      return (
        items: <ProductModel>[],
        sameShop: <ProductModel>[],
        sameCategory: <ProductModel>[],
        popular: <ProductModel>[],
      );
    }
    List<ProductModel> parse(String key) => _extractList(data[key])
        .map(ProductModel.fromJson)
        .where((p) => (p.imageUrl ?? '').trim().isNotEmpty)
        .toList();
    return (
      items: parse('items'),
      sameShop: parse('same_shop'),
      sameCategory: parse('same_category'),
      popular: parse('popular'),
    );
  }

  Future<({List<BusinessModel> businesses, List<ProductModel> products})> search(
    String query,
  ) async {
    final response = await _client.get('/search', queryParameters: {'q': query});
    final data = response.data;
    if (data is Map<String, dynamic>) {
      final businesses = _extractList(data['businesses']).map(BusinessModel.fromJson).toList();
      final products = _extractList(data['products']).map(ProductModel.fromJson).toList();
      return (businesses: businesses, products: products);
    }
    return (businesses: <BusinessModel>[], products: <ProductModel>[]);
  }

  Future<List<ReviewModel>> getReviews(String businessId) async {
    final response = await _client.get('/reviews/business/$businessId');
    return _extractList(response.data).map(ReviewModel.fromJson).toList();
  }

  Future<void> addFavorite(String businessId) async {
    await _client.post('/favorites/$businessId');
  }

  Future<void> removeFavorite(String businessId) async {
    await _client.delete('/favorites/$businessId');
  }

  Future<List<BusinessModel>> getFavorites() async {
    final response = await _client.get('/favorites');
    return _extractList(response.data).map(BusinessModel.fromJson).toList();
  }

  List<Map<String, dynamic>> _extractList(dynamic data) {
    if (data is List) return data.cast<Map<String, dynamic>>();
    if (data is Map<String, dynamic>) {
      for (final key in ['results', 'items', 'data', 'products', 'businesses', 'categories']) {
        final value = data[key];
        if (value is List) return value.cast<Map<String, dynamic>>();
      }
    }
    return [];
  }
}

final catalogRepositoryProvider = Provider<CatalogRepository>((ref) {
  return CatalogRepository(ref.watch(apiClientProvider));
});
