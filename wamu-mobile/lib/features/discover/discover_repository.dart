import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import '../../shared/models/discover_video_model.dart';

class DiscoverRepository {
  DiscoverRepository(this._client);

  final ApiClient _client;

  Future<List<DiscoverVideoModel>> getVideos({int limit = 30}) async {
    final response = await _client.get('/discover/videos', queryParameters: {'limit': limit});
    final data = response.data;
    final list = data is List
        ? data
        : (data is Map && data['videos'] is List)
            ? data['videos'] as List
            : <dynamic>[];
    return list
        .whereType<Map>()
        .map((e) => DiscoverVideoModel.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<List<DiscoverVideoModel>> getMyVideos({required String businessId}) async {
    final response = await _client.get(
      '/discover/videos/mine',
      queryParameters: {'business_id': businessId},
    );
    final data = response.data;
    final list = data is List ? data : <dynamic>[];
    return list
        .whereType<Map>()
        .map((e) => DiscoverVideoModel.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<DiscoverVideoModel> like(String videoId) async {
    final response = await _client.post('/discover/videos/$videoId/like');
    return DiscoverVideoModel.fromJson(response.data as Map<String, dynamic>);
  }

  Future<DiscoverVideoModel> unlike(String videoId) async {
    final response = await _client.delete('/discover/videos/$videoId/like');
    return DiscoverVideoModel.fromJson(response.data as Map<String, dynamic>);
  }

  Future<void> recordView(String videoId) async {
    try {
      await _client.post('/discover/videos/$videoId/view');
    } catch (_) {}
  }

  Future<void> followBusiness(String businessId) async {
    await _client.post('/discover/businesses/$businessId/follow');
  }

  Future<void> unfollowBusiness(String businessId) async {
    await _client.delete('/discover/businesses/$businessId/follow');
  }

  Future<DiscoverVideoModel> createVideo({
    required String businessId,
    required String videoUrl,
    String? caption,
    String? posterUrl,
    String? originalVideoUrl,
    String? tags,
    String? productId,
    int? fileSizeBytes,
  }) async {
    final response = await _client.post('/discover/videos', data: {
      'business_id': businessId,
      'video_url': videoUrl,
      if (caption != null && caption.isNotEmpty) 'caption': caption,
      if (posterUrl != null && posterUrl.isNotEmpty) 'poster_url': posterUrl,
      if (originalVideoUrl != null && originalVideoUrl.isNotEmpty)
        'original_video_url': originalVideoUrl,
      if (tags != null && tags.isNotEmpty) 'tags': tags,
      if (productId != null && productId.isNotEmpty) 'product_id': productId,
      if (fileSizeBytes != null && fileSizeBytes > 0) 'file_size_bytes': fileSizeBytes,
    });
    return DiscoverVideoModel.fromJson(response.data as Map<String, dynamic>);
  }

  /// Archive (hide from feed, restorable) or permanently delete.
  Future<void> deleteVideo(String videoId, {bool permanent = false}) async {
    await _client.delete(
      '/discover/videos/$videoId',
      queryParameters: permanent ? {'permanent': true} : null,
    );
  }

  Future<DiscoverVideoModel> restoreVideo(String videoId) async {
    final response = await _client.post('/discover/videos/$videoId/restore');
    return DiscoverVideoModel.fromJson(response.data as Map<String, dynamic>);
  }
}

final discoverRepositoryProvider = Provider<DiscoverRepository>((ref) {
  return DiscoverRepository(ref.watch(apiClientProvider));
});
