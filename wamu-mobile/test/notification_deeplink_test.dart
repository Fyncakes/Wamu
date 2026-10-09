import 'package:flutter_test/flutter_test.dart';
import 'package:wamu_mobile/features/profile/notifications_screen.dart';

void main() {
  test('NotificationModel parses data map', () {
    final n = NotificationModel.fromJson({
      'id': 'n1',
      'title': 'Order update',
      'body': 'Your order is now DELIVERED',
      'type': 'ORDER_STATUS',
      'is_read': false,
      'data': {'order_id': 'ord-9', 'status': 'DELIVERED'},
    });
    expect(n.data['order_id'], 'ord-9');
    expect(n.deepLink, '/orders/ord-9');
  });

  test('notificationDeepLink covers commerce + chat types', () {
    expect(
      notificationDeepLink(
        type: 'PAYMENT_SUCCESS',
        data: {'order_id': 'o1'},
      ),
      '/orders/o1',
    );
    expect(notificationDeepLink(type: 'NEW_ORDER'), '/business-owner/orders');
    expect(
      notificationDeepLink(
        type: 'ORDER_PAID',
        data: {'conversation_id': 'c-paid', 'order_id': 'o9'},
      ),
      '/chat/c-paid',
    );
    expect(
      notificationDeepLink(type: 'ORDER_PAID', data: {'order_id': 'o9'}),
      '/business-owner/orders',
    );
    expect(
      notificationDeepLink(
        type: 'DELIVERY_ASSIGNED',
        data: {'order_id': 'o2'},
      ),
      '/orders/o2',
    );
    expect(
      notificationDeepLink(
        type: 'NEW_MESSAGE',
        data: {'conversation_id': 'c1'},
      ),
      '/chat/c1',
    );
    expect(
      notificationDeepLink(
        type: 'REVIEW_REPLY',
        data: {'business_id': 'b1'},
      ),
      '/business/b1',
    );
    expect(notificationDeepLink(type: 'INCOMING_CALL'), '/calls');
    expect(notificationDeepLink(type: 'UNKNOWN'), isNull);
  });
}
