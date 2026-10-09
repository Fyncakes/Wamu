import '../utils/json_numbers.dart';

class DiscoverVideoModel {
  const DiscoverVideoModel({
    required this.id,
    required this.businessId,
    required this.businessName,
    this.businessLogoUrl,
    required this.authorId,
    this.caption,
    required this.videoUrl,
    this.posterUrl,
    this.tags,
    this.likeCount = 0,
    this.commentCount = 0,
    this.viewCount = 0,
    this.likedByMe = false,
    this.following = false,
    this.productId,
    this.productName,
    this.productPrice,
    this.currency = 'UGX',
    this.status = 'active',
    this.fileSizeBytes,
  });

  factory DiscoverVideoModel.fromJson(Map<String, dynamic> json) {
    return DiscoverVideoModel(
      id: json['id']?.toString() ?? '',
      businessId: json['business_id']?.toString() ?? '',
      businessName: json['business_name']?.toString() ?? 'Business',
      businessLogoUrl: json['business_logo_url']?.toString(),
      authorId: json['author_id']?.toString() ?? '',
      caption: json['caption']?.toString(),
      videoUrl: json['video_url']?.toString() ?? '',
      posterUrl: json['poster_url']?.toString(),
      tags: json['tags']?.toString(),
      likeCount: parseIntOrZero(json['like_count']),
      commentCount: parseIntOrZero(json['comment_count']),
      viewCount: parseIntOrZero(json['view_count']),
      likedByMe: json['liked_by_me'] == true,
      following: json['following'] == true,
      productId: json['product_id']?.toString(),
      productName: json['product_name']?.toString(),
      productPrice: parseDouble(json['product_price']),
      currency: json['currency']?.toString() ?? 'UGX',
      status: json['status']?.toString() ?? 'active',
      fileSizeBytes: parseIntOrZero(json['file_size_bytes']) == 0
          ? null
          : parseIntOrZero(json['file_size_bytes']),
    );
  }

  final String id;
  final String businessId;
  final String businessName;
  final String? businessLogoUrl;
  final String authorId;
  final String? caption;
  final String videoUrl;
  final String? posterUrl;
  final String? tags;
  final int likeCount;
  final int commentCount;
  final int viewCount;
  final bool likedByMe;
  final bool following;
  final String? productId;
  final String? productName;
  final double? productPrice;
  final String currency;
  final String status;
  final int? fileSizeBytes;

  /// Poster only — never fall back to the MP4 URL (that stalls the image layer).
  String? get displayImage {
    final p = posterUrl?.trim();
    if (p != null && p.isNotEmpty) return p;
    return null;
  }

  /// Caption may be stored as `Title|||Description` from media mapping.
  String get title {
    final c = caption?.trim() ?? '';
    if (c.isEmpty) return businessName;
    if (c.contains('|||')) return c.split('|||').first.trim();
    return c.split('\n').first.trim();
  }

  String get descriptionText {
    final c = caption?.trim() ?? '';
    if (c.contains('|||')) {
      final parts = c.split('|||');
      return parts.length > 1 ? parts.sublist(1).join('|||').trim() : '';
    }
    final lines = c.split('\n');
    if (lines.length > 1) return lines.sublist(1).join('\n').trim();
    return '';
  }

  /// Top-level browse category from tags (`Fashion/Clothing` → `Fashion`).
  String get categoryLabel {
    final t = tags?.trim() ?? '';
    if (t.isEmpty) return 'Discover';
    return t.split('/').first.trim();
  }

  String get categoryFull => (tags ?? '').trim();

  DiscoverVideoModel copyWith({
    bool? likedByMe,
    int? likeCount,
    bool? following,
  }) {
    return DiscoverVideoModel(
      id: id,
      businessId: businessId,
      businessName: businessName,
      businessLogoUrl: businessLogoUrl,
      authorId: authorId,
      caption: caption,
      videoUrl: videoUrl,
      posterUrl: posterUrl,
      tags: tags,
      likeCount: likeCount ?? this.likeCount,
      commentCount: commentCount,
      viewCount: viewCount,
      likedByMe: likedByMe ?? this.likedByMe,
      following: following ?? this.following,
      productId: productId,
      productName: productName,
      productPrice: productPrice,
      currency: currency,
      status: status,
      fileSizeBytes: fileSizeBytes,
    );
  }
}
