import '../utils/json_numbers.dart';

class ProductModel {
  const ProductModel({
    required this.id,
    required this.name,
    required this.price,
    this.businessId,
    this.description,
    this.imageUrl,
    this.categoryId,
    this.inStock = true,
    this.currency = 'UGX',
    this.stockQuantity,
    this.status = 'ACTIVE',
  });

  factory ProductModel.fromJson(Map<String, dynamic> json) {
    String? image;
    final images = json['images'];
    if (images is List && images.isNotEmpty) {
      final first = images.first;
      if (first is Map) image = first['url']?.toString();
    }
    image ??= json['image_url']?.toString();

    final stockQty = parseInt(json['stock_quantity']);
    final status = json['status']?.toString() ?? 'ACTIVE';
    final inStock = json['in_stock'] != false &&
        status != 'OUT_OF_STOCK' &&
        (stockQty == null || stockQty > 0);

    return ProductModel(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      price: parseDoubleOrZero(json['price']),
      businessId: json['business_id']?.toString(),
      description: json['description']?.toString(),
      imageUrl: image,
      categoryId: json['category_id']?.toString(),
      inStock: inStock,
      currency: json['currency']?.toString() ?? 'UGX',
      stockQuantity: stockQty,
      status: status,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'price': price,
        'business_id': businessId,
        'description': description,
        'image_url': imageUrl,
        'category_id': categoryId,
        'currency': currency,
        'stock_quantity': stockQuantity,
        'status': status,
        'in_stock': inStock,
      };

  final String id;
  final String name;
  final double price;
  final String? businessId;
  final String? description;
  final String? imageUrl;
  final String? categoryId;
  final bool inStock;
  final String currency;
  final int? stockQuantity;
  final String status;
}
