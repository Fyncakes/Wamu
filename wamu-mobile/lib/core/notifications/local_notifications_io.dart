import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

const _channelId = 'wamu_messages';
const _channelName = 'Wamu messages';
const _callChannelId = 'wamu_calls';
const _callChannelName = 'Wamu calls';

final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
bool _ready = false;

typedef NotificationTapCallback = void Function(String? payload);

NotificationTapCallback? onWamuNotificationTap;

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
    onDidReceiveNotificationResponse: (response) {
      onWamuNotificationTap?.call(response.payload);
    },
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
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        _callChannelId,
        _callChannelName,
        description: 'Incoming voice and video calls',
        importance: Importance.max,
        playSound: true,
        enableVibration: true,
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
  bool callAlert = false,
}) async {
  await ensureLocalNotificationsReady();
  final channelId = callAlert ? _callChannelId : _channelId;
  final channelName = callAlert ? _callChannelName : _channelName;
  final id = payload != null && payload.startsWith('call:')
      ? payload.hashCode.abs() % 100000
      : DateTime.now().millisecondsSinceEpoch.remainder(100000);
  await _plugin.show(
    id,
    title,
    body,
    NotificationDetails(
      android: AndroidNotificationDetails(
        channelId,
        channelName,
        channelDescription: callAlert
            ? 'Incoming voice and video calls'
            : 'Chat and order alerts from Wamu',
        importance: callAlert ? Importance.max : Importance.high,
        priority: callAlert ? Priority.max : Priority.high,
        category: callAlert ? AndroidNotificationCategory.call : null,
        fullScreenIntent: callAlert,
        ongoing: callAlert,
        autoCancel: !callAlert,
        icon: '@mipmap/ic_launcher',
      ),
      iOS: DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
        interruptionLevel: callAlert
            ? InterruptionLevel.timeSensitive
            : InterruptionLevel.active,
      ),
    ),
    payload: payload,
  );
}

Future<void> cancelWamuNotificationForPayload(String payload) async {
  if (!_ready) return;
  final id = payload.hashCode.abs() % 100000;
  await _plugin.cancel(id);
}
