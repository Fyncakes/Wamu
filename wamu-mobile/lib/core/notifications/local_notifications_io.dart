import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

const _channelId = 'wamu_messages';
const _channelName = 'Wamu messages';

final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
bool _ready = false;

Future<void> ensureLocalNotificationsReady() async {
  if (_ready) return;
  const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  const iosInit = DarwinInitializationSettings(
    requestAlertPermission: true,
    requestBadgePermission: true,
    requestSoundPermission: true,
  );
  await _plugin.initialize(
    const InitializationSettings(android: androidInit, iOS: iosInit),
  );

  if (Platform.isAndroid) {
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        _channelId,
        _channelName,
        description: 'Chat and order alerts from Wamu',
        importance: Importance.high,
      ),
    );
    await android?.requestNotificationsPermission();
  }
  _ready = true;
}

Future<void> showWamuLocalNotification({
  required String title,
  required String body,
  String? payload,
}) async {
  await ensureLocalNotificationsReady();
  await _plugin.show(
    DateTime.now().millisecondsSinceEpoch.remainder(100000),
    title,
    body,
    NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: 'Chat and order alerts from Wamu',
        importance: Importance.high,
        priority: Priority.high,
        icon: '@mipmap/ic_launcher',
      ),
      iOS: const DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      ),
    ),
    payload: payload,
  );
}
