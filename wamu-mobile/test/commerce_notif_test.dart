import 'package:flutter_test/flutter_test.dart';
import 'package:wamu_mobile/features/profile/commerce_notif_provider.dart';
import 'package:wamu_mobile/features/profile/notifications_screen.dart';

void main() {
  test('isCommerceNotificationType covers order rails', () {
    expect(isCommerceNotificationType('NEW_ORDER'), isTrue);
    expect(isCommerceNotificationType('order_paid'), isTrue);
    expect(isCommerceNotificationType('DELIVERY_ASSIGNED'), isTrue);
    expect(isCommerceNotificationType('NEW_MESSAGE'), isFalse);
    expect(isCommerceNotificationType('INCOMING_CALL'), isFalse);
  });

  test('commerce types deeplink to commerce routes', () {
    expect(notificationDeepLink(type: 'NEW_ORDER'), '/business-owner/orders');
    expect(
      notificationDeepLink(type: 'PAYMENT_SUCCESS', data: {'order_id': 'o1'}),
      '/orders/o1',
    );
    expect(
      notificationDeepLink(type: 'DELIVERY_ASSIGNED', data: {'order_id': 'o2'}),
      '/orders/o2',
    );
  });
}
