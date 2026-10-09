import 'package:flutter/material.dart';

/// Shared payment-status coloring for customer + merchant order lists.
Color orderPaymentColor(String? paymentStatus) {
  switch ((paymentStatus ?? '').toUpperCase()) {
    case 'SUCCESS':
      return Colors.green.shade700;
    case 'PENDING':
    case 'PROCESSING':
      return Colors.orange.shade800;
    case 'FAILED':
      return Colors.red.shade700;
    case 'REFUNDED':
      return Colors.blueGrey;
    default:
      return Colors.grey.shade700;
  }
}

/// Next merchant fulfillment status (null = terminal).
String? nextFulfillmentStatus(String status) {
  const next = {
    'PENDING': 'CONFIRMED',
    'CONFIRMED': 'PROCESSING',
    'PROCESSING': 'READY',
    'READY': 'OUT_FOR_DELIVERY',
    'OUT_FOR_DELIVERY': 'DELIVERED',
  };
  return next[status.toUpperCase()];
}
