import 'dart:typed_data';

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
    bool? isActive,
  }) async {
    final response = await _client.patch(
      '/products/$productId',
      data: {
        if (name != null) 'name': name,
        if (price != null) 'price': price,
        if (description != null) 'description': description,
        if (stockQuantity != null) 'stock_quantity': stockQuantity,
        if (status != null) 'status': status,
        if (isActive != null) 'is_active': isActive,
      },
    );
    return ProductModel.fromJson(response.data as Map<String, dynamic>);
  }

  /// Create the product then attach the photo. Buyers only see items with a photo.
  Future<ProductModel> createProductWithImage({
    required String businessId,
    required String name,
    required double price,
    required Uint8List imageBytes,
    String? description,
    int stockQuantity = 10,
    String filename = 'product.jpg',
  }) async {
    if (imageBytes.isEmpty) {
      throw StateError('Product photo is empty — pick the photo again');
    }
    final created = await createProduct(
      businessId: businessId,
      name: name,
      price: price,
      description: description,
      stockQuantity: stockQuantity,
    );
    try {
      return await _uploadImageBytesWithRetry(
        created.id,
        imageBytes,
        filename: filename,
      );
    } catch (e) {
      // Hide incomplete listings from buyers until the owner adds a photo.
      try {
        await updateProduct(
          productId: created.id,
          status: 'INACTIVE',
          isActive: false,
        );
      } catch (_) {}
      throw StateError(
        'Product saved but the photo failed to upload. '
        'Open the product, tap Edit, and add the photo again so buyers can see it.',
      );
    }
  }

  Future<ProductModel> uploadImage(String productId, XFile file) async {
    final bytes = await file.readAsBytes();
    var filename = file.name.isNotEmpty ? file.name : 'product.jpg';
    return uploadImageBytes(productId, bytes, filename: filename, mimeType: file.mimeType);
  }

  Future<ProductModel> uploadImageBytes(
    String productId,
    Uint8List bytes, {
    String filename = 'product.jpg',
    String? mimeType,
  }) async {
    if (bytes.isEmpty) {
      throw StateError('Photo data is empty');
    }
    var safeName = filename.isNotEmpty ? filename : 'product.jpg';
    final lower = safeName.toLowerCase();
    final mime = (mimeType ?? '').toLowerCase();
    var contentType = 'image/jpeg';
    if (lower.endsWith('.png') || mime.contains('png')) {
      contentType = 'image/png';
      if (!lower.endsWith('.png')) safeName = '$safeName.png';
    } else if (lower.endsWith('.webp') || mime.contains('webp')) {
      contentType = 'image/webp';
      if (!lower.endsWith('.webp')) safeName = '$safeName.webp';
    } else if (lower.endsWith('.gif') || mime.contains('gif')) {
      contentType = 'image/gif';
    } else if (!lower.endsWith('.jpg') && !lower.endsWith('.jpeg')) {
      safeName = '$safeName.jpg';
    }

    final form = FormData.fromMap({
      'file': MultipartFile.fromBytes(
        bytes,
        filename: safeName,
        contentType: MediaType.parse(contentType),
      ),
    });
    // Do NOT set Content-Type manually — Dio must add the multipart boundary.
    final response = await _client.dio.post(
      '/products/$productId/images',
      data: form,
    );
    return ProductModel.fromJson(response.data as Map<String, dynamic>);
  }

  Future<ProductModel> _uploadImageBytesWithRetry(
    String productId,
    Uint8List bytes, {
    required String filename,
  }) async {
    try {
      return await uploadImageBytes(productId, bytes, filename: filename);
    } catch (_) {
      await Future<void>.delayed(const Duration(milliseconds: 700));
      return uploadImageBytes(productId, bytes, filename: filename);
    }
  }
}

final ownerProductsRepositoryProvider = Provider<OwnerProductsRepository>((ref) {
  return OwnerProductsRepository(ref.watch(apiClientProvider));
});
