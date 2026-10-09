/// Helpers for live order / delivery tracking UI.
library;

bool orderNeedsLiveTracking(String orderStatus, {String? paymentStatus}) {
  final o = orderStatus.toUpperCase();
  if (o == 'DELIVERED' || o == 'CANCELLED' || o == 'REFUNDED') return false;
  final p = (paymentStatus ?? '').toUpperCase();
  if (p == 'PENDING' || p == 'PROCESSING') return true;
  return true;
}

bool listHasActiveOrders(Iterable<({String status, String? paymentStatus})> orders) {
  for (final o in orders) {
    if (orderNeedsLiveTracking(o.status, paymentStatus: o.paymentStatus)) {
      return true;
    }
  }
  return false;
}

String deliveryStatusLabel(String? status) {
  switch ((status ?? '').toUpperCase()) {
    case 'REQUESTED':
      return 'Looking for a rider';
    case 'ACCEPTED':
      return 'Rider assigned';
    case 'GOING_TO_PICKUP':
      return 'Rider going to the shop';
    case 'AT_PICKUP':
      return 'Rider at the shop';
    case 'PICKED_UP':
      return 'Picked up';
    case 'IN_TRANSIT':
      return 'On the way to you';
    case 'DELIVERED':
      return 'Delivered';
    case 'CANCELLED':
      return 'Delivery cancelled';
    default:
      return status?.isNotEmpty == true ? status! : 'Pending';
  }
}
