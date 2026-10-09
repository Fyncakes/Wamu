import '../utils/json_numbers.dart';

class BusinessModel {
  const BusinessModel({
    required this.id,
    required this.name,
    this.description,
    this.categoryId,
    this.imageUrl,
    this.coverUrl,
    this.rating,
    this.reviewCount,
    this.address,
    this.city,
    this.verificationStatus = 'UNVERIFIED',
    this.phone,
    this.payoutPhone,
    this.payoutProvider,
  });

  factory BusinessModel.fromJson(Map<String, dynamic> json) {
    final location = json['location'] as Map<String, dynamic>?;
    final addressParts = <String>[
      if (location?['address_line'] != null) location!['address_line'].toString(),
      if (location?['city'] != null) location!['city'].toString(),
    ];
    return BusinessModel(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      description: json['description']?.toString(),
      categoryId: json['category_id']?.toString(),
      imageUrl: json['logo_url']?.toString() ?? json['image_url']?.toString(),
      coverUrl: json['cover_url']?.toString(),
      rating: parseDouble(json['rating']),
      reviewCount: parseInt(json['review_count']),
      address: addressParts.isEmpty
          ? json['address']?.toString()
          : addressParts.join(', '),
      city: location?['city']?.toString(),
      verificationStatus: json['verification_status']?.toString() ?? 'UNVERIFIED',
      phone: json['phone']?.toString(),
      payoutPhone: json['payout_phone']?.toString(),
      payoutProvider: json['payout_provider']?.toString(),
    );
  }

  final String id;
  final String name;
  final String? description;
  final String? categoryId;
  final String? imageUrl;
  final String? coverUrl;
  final double? rating;
  final int? reviewCount;
  final String? address;
  final String? city;
  final String verificationStatus;
  final String? phone;
  final String? payoutPhone;
  final String? payoutProvider;

  bool get isVerified => verificationStatus == 'VERIFIED';

  /// Effective MoMo MSISDN for disbursements (explicit payout → business phone).
  String? get effectivePayoutPhone {
    final p = payoutPhone?.trim();
    if (p != null && p.isNotEmpty) return p;
    final b = phone?.trim();
    if (b != null && b.isNotEmpty) return b;
    return null;
  }
}
