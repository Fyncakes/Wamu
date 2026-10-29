typedef NotificationTapCallback = void Function(String? payload);

NotificationTapCallback? onWamuNotificationTap;

Future<void> ensureLocalNotificationsReady() async {}

Future<void> showWamuLocalNotification({
  required String title,
  required String body,
  String? payload,
  bool callAlert = false,
}) async {}

Future<void> cancelWamuNotificationForPayload(String payload) async {}
