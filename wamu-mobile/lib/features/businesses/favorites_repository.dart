import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import '../../shared/models/business_model.dart';
import '../../shared/models/review_model.dart';
import '../home/catalog_repository.dart';

class FavoritesRepository {
  FavoritesRepository(this._catalog);

  final CatalogRepository _catalog;

  Future<void> addFavorite(String businessId) => _catalog.addFavorite(businessId);
  Future<void> removeFavorite(String businessId) => _catalog.removeFavorite(businessId);
  Future<List<BusinessModel>> list() => _catalog.getFavorites();
}

class ReviewsRepository {
  ReviewsRepository(this._client, this._catalog);

  final ApiClient _client;
  final CatalogRepository _catalog;

  Future<List<ReviewModel>> getReviews(String businessId) => _catalog.getReviews(businessId);

  Future<ReviewModel> postReview({
    required String businessId,
    required int rating,
    required String orderId,
    String? comment,
    int? riderRating,
  }) async {
    final response = await _client.post('/reviews', data: {
      'business_id': businessId,
      'order_id': orderId,
      'rating': rating,
      if (comment != null && comment.isNotEmpty) 'comment': comment,
      if (riderRating != null) 'rider_rating': riderRating,
    });
    return ReviewModel.fromJson(response.data as Map<String, dynamic>);
  }

  Future<ReviewModel> replyToReview({
    required String reviewId,
    required String reply,
  }) async {
    final response = await _client.post('/reviews/$reviewId/reply', data: {
      'reply': reply,
    });
    return ReviewModel.fromJson(response.data as Map<String, dynamic>);
  }
}

final favoritesRepositoryProvider = Provider<FavoritesRepository>((ref) {
  return FavoritesRepository(ref.watch(catalogRepositoryProvider));
});

final reviewsRepositoryProvider = Provider<ReviewsRepository>((ref) {
  return ReviewsRepository(
    ref.watch(apiClientProvider),
    ref.watch(catalogRepositoryProvider),
  );
});
