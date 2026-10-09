import 'package:flutter_test/flutter_test.dart';
import 'package:wamu_mobile/shared/models/order_model.dart';
import 'package:wamu_mobile/shared/utils/order_payment_style.dart';

void main() {
  test('nextFulfillmentStatus walks merchant FSM', () {
    expect(nextFulfillmentStatus('PENDING'), 'CONFIRMED');
    expect(nextFulfillmentStatus('OUT_FOR_DELIVERY'), 'DELIVERED');
    expect(nextFulfillmentStatus('DELIVERED'), isNull);
  });

  test('OrderModel parses payment fields and labels', () {
    final paid = OrderModel.fromJson({
      'id': 'o1',
      'status': 'CONFIRMED',
      'total': 10000,
      'payment_status': 'SUCCESS',
      'payment_provider': 'MTN',
      'items': [],
    });
    expect(paid.paymentStatus, 'SUCCESS');
    expect(paid.paymentProvider, 'MTN');
    expect(paid.paymentLabel, 'Paid · MTN');
    expect(paid.canRetryPayment, isFalse);

    final waiting = OrderModel.fromJson({
      'id': 'o2',
      'status': 'PENDING',
      'total': 5000,
      'payment_status': 'PROCESSING',
      'payment_provider': 'AIRTEL',
      'items': [],
    });
    expect(waiting.paymentLabel, 'Waiting for phone…');

    final failed = OrderModel.fromJson({
      'id': 'o3',
      'status': 'PENDING',
      'total': 5000,
      'payment_status': 'FAILED',
      'payment_provider': 'MTN',
      'items': [],
    });
    expect(failed.paymentLabel, 'Failed — retry');
    expect(failed.canRetryPayment, isTrue);

    final unpaid = OrderModel.fromJson({
      'id': 'o4',
      'status': 'PENDING',
      'total': 1000,
      'items': [],
    });
    expect(unpaid.paymentLabel, 'Unpaid');
  });
}
