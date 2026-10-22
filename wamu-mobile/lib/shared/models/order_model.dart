import '../utils/json_numbers.dart';

class OrderModel {
  const OrderModel({
    required this.id,
    required this.status,
    required this.total,
    this.businessId,
    this.businessName,
    this.businessLogoUrl,
    this.items = const [],
    this.createdAt,
    this.paymentStatus,
    this.paymentProvider,
  });

  factory OrderModel.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'] as List<dynamic>? ?? [];
    return OrderModel(
      id: json['id']?.toString() ?? '',
      status: json['status']?.toString() ?? 'PENDING',
      total: parseDoubleOrZero(json['total']),
      businessId: json['business_id']?.toString(),
      businessName: json['business_name']?.toString(),
      businessLogoUrl: json['business_logo_url']?.toString(),
      createdAt: json['created_at']?.toString(),
      paymentStatus: json['payment_status']?.toString(),
      paymentProvider: json['payment_provider']?.toString(),
      items: rawItems
          .map((e) => OrderItemModel.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  final String id;
  final String status;
  final double total;
  final String? businessId;
  final String? businessName;
  final String? businessLogoUrl;
  final List<OrderItemModel> items;
  final String? createdAt;
  final String? paymentStatus;
  final String? paymentProvider;

  /// Best thumbnail for list cards: first item photo, else shop logo.
  String? get previewImageUrl {
    for (final item in items) {
      final url = item.imageUrl?.trim();
      if (url != null && url.isNotEmpty) return url;
    }
    final logo = businessLogoUrl?.trim();
    if (logo != null && logo.isNotEmpty) return logo;
    return null;
  }

  /// Human-readable payment line for list/detail (order FSM stays separate).
  String get paymentLabel {
    final s = paymentStatus?.toUpperCase();
    final provider = _prettyProvider(paymentProvider);
    if (s == null || s.isEmpty) {
      if (status.toUpperCase() == 'PENDING') return 'Unpaid';
      return '';
    }
    switch (s) {
      case 'SUCCESS':
        return 'Paid · $provider';
      case 'PENDING':
      case 'PROCESSING':
        return 'Waiting for phone…';
      case 'FAILED':
        return 'Failed — retry';
      case 'REFUNDED':
        return 'Refunded';
      default:
        return s;
    }
  }

  /// Show Pay when unpaid / failed / still waiting on MoMo.
  bool get canRetryPayment {
    final pay = (paymentStatus ?? '').toUpperCase();
    if (pay == 'SUCCESS' || pay == 'REFUNDED') return false;
    final st = status.toUpperCase();
    if (st == 'CANCELLED' || st == 'DELIVERED') return false;
    // No payment row yet, failed attempt, or in-flight MoMo.
    return pay.isEmpty ||
        pay == 'UNPAID' ||
        pay == 'FAILED' ||
        pay == 'PENDING' ||
        pay == 'PROCESSING';
  }

  bool get needsFirstPayment {
    final pay = (paymentStatus ?? '').toUpperCase();
    return pay.isEmpty || pay == 'UNPAID';
  }

  static String _prettyProvider(String? raw) {
    switch ((raw ?? '').toUpperCase()) {
      case 'MTN':
        return 'MTN';
      case 'AIRTEL':
        return 'Airtel';
      case 'MOCK':
        return 'Test pay';
      case 'CARD':
        return 'Card (unavailable)';
      case '':
        return 'MoMo';
      default:
        return raw!;
    }
  }
}

class OrderItemModel {
  const OrderItemModel({
    required this.productId,
    required this.name,
    required this.quantity,
    required this.price,
    this.imageUrl,
  });

  factory OrderItemModel.fromJson(Map<String, dynamic> json) {
    return OrderItemModel(
      productId: json['product_id']?.toString() ?? '',
      name: json['product_name']?.toString() ?? json['name']?.toString() ?? '',
      quantity: parseInt(json['quantity']) ?? 1,
      price: parseDouble(json['unit_price']) ?? parseDoubleOrZero(json['price']),
      imageUrl: json['image_url']?.toString(),
    );
  }

  final String productId;
  final String name;
  final int quantity;
  final double price;
  final String? imageUrl;
}
