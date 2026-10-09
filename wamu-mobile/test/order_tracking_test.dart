import 'package:flutter_test/flutter_test.dart';
import 'package:wamu_mobile/shared/utils/order_tracking.dart';

void main() {
  test('orderNeedsLiveTracking stops on terminal statuses', () {
    expect(orderNeedsLiveTracking('DELIVERED'), isFalse);
    expect(orderNeedsLiveTracking('CANCELLED'), isFalse);
    expect(orderNeedsLiveTracking('REFUNDED'), isFalse);
  });

  test('orderNeedsLiveTracking continues for open commerce states', () {
    expect(orderNeedsLiveTracking('PENDING'), isTrue);
    expect(orderNeedsLiveTracking('CONFIRMED'), isTrue);
    expect(orderNeedsLiveTracking('OUT_FOR_DELIVERY'), isTrue);
    expect(orderNeedsLiveTracking('PENDING', paymentStatus: 'PROCESSING'), isTrue);
  });

  test('listHasActiveOrders detects open rows', () {
    expect(
      listHasActiveOrders([
        (status: 'DELIVERED', paymentStatus: 'SUCCESS'),
        (status: 'CANCELLED', paymentStatus: null),
      ]),
      isFalse,
    );
    expect(
      listHasActiveOrders([
        (status: 'DELIVERED', paymentStatus: 'SUCCESS'),
        (status: 'OUT_FOR_DELIVERY', paymentStatus: 'SUCCESS'),
      ]),
      isTrue,
    );
  });

  test('deliveryStatusLabel covers rider FSM', () {
    expect(deliveryStatusLabel('IN_TRANSIT'), 'On the way to you');
    expect(deliveryStatusLabel('DELIVERED'), 'Delivered');
    expect(deliveryStatusLabel(null), 'Pending');
  });
}
