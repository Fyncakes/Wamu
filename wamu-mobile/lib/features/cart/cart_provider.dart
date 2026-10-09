import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/storage/secure_storage.dart';
import '../../shared/models/product_model.dart';

/// Cart item — multi-shop bags group by business at checkout.
class CartItem {
  CartItem({required this.product, this.quantity = 1});

  final ProductModel product;
  int quantity;

  double get subtotal => product.price * quantity;

  Map<String, dynamic> toJson() => {
        'product': product.toJson(),
        'quantity': quantity,
      };

  factory CartItem.fromJson(Map<String, dynamic> json) {
    return CartItem(
      product: ProductModel.fromJson(json['product'] as Map<String, dynamic>),
      quantity: (json['quantity'] as num?)?.toInt() ?? 1,
    );
  }
}

class CartNotifier extends StateNotifier<List<CartItem>> {
  CartNotifier(this._storage) : super([]) {
    _restore();
  }

  final SecureStorageService _storage;
  static const _cartKey = 'wamu_cart_v2';
  bool _ready = false;

  /// First shop in the bag (UI helper). Prefer [shopIds] / [itemsByShop].
  String? get businessId => state.isEmpty ? null : state.first.product.businessId;

  List<String> get shopIds {
    final seen = <String>{};
    final ordered = <String>[];
    for (final item in state) {
      final id = item.product.businessId;
      if (id == null || id.isEmpty || seen.contains(id)) continue;
      seen.add(id);
      ordered.add(id);
    }
    return ordered;
  }

  int get shopCount => shopIds.length;

  Map<String, List<CartItem>> get itemsByShop {
    final map = <String, List<CartItem>>{};
    for (final item in state) {
      final id = item.product.businessId;
      if (id == null || id.isEmpty) continue;
      map.putIfAbsent(id, () => []).add(item);
    }
    return map;
  }

  Future<void> _restore() async {
    try {
      var raw = await _storage.read(_cartKey);
      raw ??= await _storage.read('wamu_cart_v1');
      if (raw == null || raw.isEmpty) {
        _ready = true;
        return;
      }
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        state = decoded
            .whereType<Map>()
            .map((e) => CartItem.fromJson(Map<String, dynamic>.from(e)))
            .toList();
      }
    } catch (_) {
      state = [];
    } finally {
      _ready = true;
    }
  }

  Future<void> _persist() async {
    if (!_ready) return;
    if (state.isEmpty) {
      await _storage.delete(_cartKey);
      return;
    }
    await _storage.write(
      _cartKey,
      jsonEncode(state.map((e) => e.toJson()).toList()),
    );
  }

  void addProduct(ProductModel product, {int quantity = 1}) {
    if (product.businessId == null || product.businessId!.isEmpty) {
      throw StateError('Product missing business_id');
    }
    final index = state.indexWhere((item) => item.product.id == product.id);
    if (index >= 0) {
      final updated = List<CartItem>.from(state);
      updated[index].quantity += quantity;
      state = updated;
    } else {
      state = [...state, CartItem(product: product, quantity: quantity)];
    }
    _persist();
  }

  void removeProduct(String productId) {
    state = state.where((item) => item.product.id != productId).toList();
    _persist();
  }

  void updateQuantity(String productId, int quantity) {
    if (quantity <= 0) {
      removeProduct(productId);
      return;
    }
    state = [
      for (final item in state)
        if (item.product.id == productId)
          CartItem(product: item.product, quantity: quantity)
        else
          item,
    ];
    _persist();
  }

  void clear() {
    state = [];
    _persist();
  }

  void patchProduct(ProductModel product) {
    final index = state.indexWhere((item) => item.product.id == product.id);
    if (index < 0) return;
    final current = state[index];
    state = [
      for (var i = 0; i < state.length; i++)
        if (i == index) CartItem(product: product, quantity: current.quantity) else state[i],
    ];
    _persist();
  }

  double get total => state.fold(0, (sum, item) => sum + item.subtotal);

  /// Single-shop payload for POST /orders.
  Map<String, dynamic> toOrderPayload({
    String fulfillment = 'PICKUP',
    String? deliveryAddress,
    String? note,
  }) {
    final biz = businessId;
    if (biz == null) throw StateError('Empty cart');
    if (shopCount > 1) {
      throw StateError('Use toBatchOrderPayload for multi-shop carts');
    }
    return {
      'business_id': biz,
      'fulfillment': fulfillment,
      if (deliveryAddress != null) 'delivery_address': deliveryAddress,
      if (note != null) 'customer_note': note,
      'items': [
        for (final item in state)
          {'product_id': item.product.id, 'quantity': item.quantity},
      ],
    };
  }

  /// Multi-shop payload for POST /orders/batch — one sub-order per merchant.
  Map<String, dynamic> toBatchOrderPayload({
    String fulfillment = 'PICKUP',
    String? deliveryAddress,
    String? note,
  }) {
    if (state.isEmpty) throw StateError('Empty cart');
    final byShop = itemsByShop;
    if (byShop.isEmpty) throw StateError('Cart items missing business_id');
    return {
      'fulfillment': fulfillment,
      if (deliveryAddress != null) 'delivery_address': deliveryAddress,
      if (note != null) 'customer_note': note,
      'shops': [
        for (final entry in byShop.entries)
          {
            'business_id': entry.key,
            'items': [
              for (final item in entry.value)
                {'product_id': item.product.id, 'quantity': item.quantity},
            ],
          },
      ],
    };
  }

  String newIdempotencyKey() => const Uuid().v4();
}

final cartProvider = StateNotifierProvider<CartNotifier, List<CartItem>>((ref) {
  return CartNotifier(ref.watch(secureStorageProvider));
});

final cartTotalProvider = Provider<double>((ref) {
  final items = ref.watch(cartProvider);
  return items.fold(0.0, (sum, item) => sum + item.subtotal);
});
