import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import '../../shared/models/order_model.dart';
import '../../shared/utils/json_numbers.dart';

class OrdersRepository {
  OrdersRepository(this._client);

  final ApiClient _client;

  Future<List<OrderModel>> getOrders() async {
    final response = await _client.get('/orders');
    return _extractList(response.data).map(OrderModel.fromJson).toList();
  }

  Future<List<OrderModel>> getBusinessOrders(String businessId) async {
    final response = await _client.get('/orders/business/$businessId');
    return _extractList(response.data).map(OrderModel.fromJson).toList();
  }

  Future<OrderModel> createOrder(Map<String, dynamic> payload) async {
    final response = await _client.post('/orders', data: payload);
    return OrderModel.fromJson(response.data as Map<String, dynamic>);
  }

  /// Multi-shop checkout — one parent batch, one sub-order per merchant.
  Future<({
    String checkoutBatchId,
    List<OrderModel> orders,
    double subtotal,
    double deliveryFee,
    double total,
  })> createOrderBatch(Map<String, dynamic> payload) async {
    final response = await _client.post('/orders/batch', data: payload);
    final data = response.data as Map<String, dynamic>;
    final rawOrders = data['orders'];
    final orders = <OrderModel>[];
    if (rawOrders is List) {
      for (final entry in rawOrders) {
        if (entry is Map) {
          orders.add(OrderModel.fromJson(Map<String, dynamic>.from(entry)));
        }
      }
    }
    if (orders.isEmpty) {
      throw StateError('Batch checkout returned no merchant orders');
    }
    // FastAPI Decimal fields often arrive as strings — never cast as num.
    return (
      checkoutBatchId: data['checkout_batch_id']?.toString() ?? '',
      orders: orders,
      subtotal: parseDoubleOrZero(data['subtotal']),
      deliveryFee: parseDoubleOrZero(data['delivery_fee']),
      total: parseDoubleOrZero(data['total']),
    );
  }

  Future<OrderModel> reviseReceipt(String orderId, Map<String, dynamic> payload) async {
    final response = await _client.patch('/orders/$orderId/receipt', data: payload);
    return OrderModel.fromJson(response.data as Map<String, dynamic>);
  }

  Future<OrderModel> getOrder(String id) async {
    final response = await _client.get('/orders/$id');
    return OrderModel.fromJson(response.data as Map<String, dynamic>);
  }

  Future<OrderModel> updateStatus(String orderId, String status) async {
    final response = await _client.patch(
      '/orders/$orderId/status',
      data: {'status': status},
    );
    return OrderModel.fromJson(response.data as Map<String, dynamic>);
  }

  Future<Map<String, dynamic>> payOrder({
    required String orderId,
    required String idempotencyKey,
    String provider = 'MOCK',
    String? phone,
  }) async {
    final response = await _client.post('/payments', data: {
      'order_id': orderId,
      'provider': provider,
      'idempotency_key': idempotencyKey,
      if (phone != null && phone.isNotEmpty) 'phone': phone,
    });
    return response.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getPayment(String paymentId) async {
    final response = await _client.get('/payments/$paymentId');
    return response.data as Map<String, dynamic>;
  }

  /// Ask the API to re-check MoMo status (PENDING → SUCCESS/FAILED).
  Future<Map<String, dynamic>> refreshPayment(String paymentId) async {
    final response = await _client.post('/payments/$paymentId/refresh');
    return response.data as Map<String, dynamic>;
  }

  /// Initiate MoMo and poll until SUCCESS/FAILED or [timeout] elapses.
  Future<Map<String, dynamic>> payOrderAndAwait({
    required String orderId,
    required String idempotencyKey,
    String provider = 'MTN',
    String? phone,
    Duration timeout = const Duration(seconds: 45),
    Duration interval = const Duration(seconds: 2),
    void Function(String status)? onStatus,
  }) async {
    var payment = await payOrder(
      orderId: orderId,
      idempotencyKey: idempotencyKey,
      provider: provider,
      phone: phone,
    );
    var status = (payment['status']?.toString() ?? '').toUpperCase();
    onStatus?.call(status);
    if (status == 'SUCCESS' || status == 'FAILED') return payment;

    final id = payment['id']?.toString();
    if (id == null || id.isEmpty) return payment;

    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(interval);
      payment = await refreshPayment(id);
      status = (payment['status']?.toString() ?? '').toUpperCase();
      onStatus?.call(status);
      if (status == 'SUCCESS' || status == 'FAILED') return payment;
    }
    return payment;
  }

  Future<Map<String, dynamic>> createDispute({
    required String orderId,
    required String reason,
    String? description,
  }) async {
    final response = await _client.post('/disputes', data: {
      'order_id': orderId,
      'reason': reason,
      if (description != null && description.isNotEmpty) 'description': description,
    });
    return response.data as Map<String, dynamic>;
  }

  Future<List<Map<String, dynamic>>> listBusinessDisputes() async {
    final response = await _client.get('/disputes/business');
    return _extractList(response.data);
  }

  List<Map<String, dynamic>> _extractList(dynamic data) {
    if (data is List) return data.cast<Map<String, dynamic>>();
    if (data is Map<String, dynamic>) {
      for (final key in ['orders', 'results', 'items', 'data']) {
        final value = data[key];
        if (value is List) return value.cast<Map<String, dynamic>>();
      }
    }
    return [];
  }
}

final ordersRepositoryProvider = Provider<OrdersRepository>((ref) {
  return OrdersRepository(ref.watch(apiClientProvider));
});
