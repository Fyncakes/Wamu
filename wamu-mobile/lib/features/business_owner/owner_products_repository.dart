import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http_parser/http_parser.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/network/api_client.dart';
import '../../shared/models/business_model.dart';
import '../../shared/models/product_model.dart';

/// Owner-side product CRUD + image upload against existing FastAPI routes.
class OwnerProductsRepository {
  OwnerProductsRepository(this._client);

  final ApiClient _client;

  Future<List<BusinessModel>> myBusinesses() async {
    final response = await _client.get('/businesses/mine');
    final data = response.data;
    if (data is List) {
      return data
          .cast<Map<String, dynamic>>()
          .map(BusinessModel.fromJson)
          .toList();
    }
    return [];
  }

  Future<List<ProductModel>> listProducts(String businessId) async {
    final response = await _client.get('/products/business/$businessId/manage');
    final data = response.data;
    if (data is List) {
      return data
          .cast<Map<String, dynamic>>()
          .map(ProductModel.fromJson)
          .toList();
    }
    return [];
  }

  Future<ProductModel> createProduct({
    required String businessId,
    required String name,
    required double price,
    String? description,
    int stockQuantity = 10,
  }) async {
    final response = await _client.post(
      '/products/business/$businessId',
      data: {
        'name': name,
        'price': price,
        if (description != null && description.isNotEmpty) 'description': description,
        'currency': 'UGX',
        'stock_quantity': stockQuantity,
      },
    );
    return ProductModel.fromJson(response.data as Map<String, dynamic>);
  }

  Future<ProductModel> updateProduct({
    required String productId,
    String? name,
    double? price,
    String? description,
    int? stockQuantity,
    String? status,
  }) async {
    final response = await _client.patch(
      '/products/$productId',
      data: {
        if (name != null) 'name': name,
        if (price != null) 'price': price,
        if (description != null) 'description': description,
        if (stockQuantity != null) 'stock_quantity': stockQuantity,
        if (status != null) 'status': status,
      },
    );
    return ProductModel.fromJson(response.data as Map<String, dynamic>);
  }

  Future<ProductModel> uploadImage(String productId, XFile file) async {
    final bytes = await file.readAsBytes();
    var filename = file.name.isNotEmpty ? file.name : 'product.jpg';
    final lower = filename.toLowerCase();
    String contentType = 'image/jpeg';
    if (lower.endsWith('.png') || (file.mimeType ?? '').contains('png')) {
      contentType = 'image/png';
      if (!lower.endsWith('.png')) filename = '$filename.png';
    } else if (lower.endsWith('.webp') || (file.mimeType ?? '').contains('webp')) {
      contentType = 'image/webp';
      if (!lower.endsWith('.webp')) filename = '$filename.webp';
    } else if (lower.endsWith('.gif') || (file.mimeType ?? '').contains('gif')) {
      contentType = 'image/gif';
    } else if (!lower.endsWith('.jpg') && !lower.endsWith('.jpeg')) {
      filename = '$filename.jpg';
    }
    final form = FormData.fromMap({
      'file': MultipartFile.fromBytes(
        bytes,
        filename: filename,
        contentType: MediaType.parse(contentType),
      ),
    });
    final response = await _client.dio.post(
      '/products/$productId/images',
      data: form,
      options: Options(contentType: 'multipart/form-data'),
    );
    return ProductModel.fromJson(response.data as Map<String, dynamic>);
  }
}

final ownerProductsRepositoryProvider = Provider<OwnerProductsRepository>((ref) {
  return OwnerProductsRepository(ref.watch(apiClientProvider));
});
