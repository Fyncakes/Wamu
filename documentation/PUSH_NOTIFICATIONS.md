# Push notifications (data-only FCM)

Wamu never puts chat plaintext in the OS notification channel. Push wakes the
app with a generic label; the authenticated in-app inbox still stores a preview.

## Flow

1. Client registers FCM token after login (`PushBootstrap.syncToken`)  
   → `PUT /api/v1/devices/push-token`  
2. On new chat message (member not muted) → Celery `wamu.send_push_notification`  
3. Worker loads tokens → provider sends **data-only** payload:

```json
{
  "data": {
    "type": "NEW_MESSAGE",
    "conversation_id": "<uuid>",
    "title": "Wamu",
    "body": "New message"
  }
}
```

No top-level FCM `notification` block (avoids lock-screen message text).

## Env (backend)

```bash
# Empty = MockPushProvider (logs only — fine for local/Celery demos)
FCM_SERVER_KEY=
```

Set `FCM_SERVER_KEY` from Firebase Cloud Messaging (legacy server key) for staging.

## Mobile (store builds)

Chrome / web demos **skip FCM** (placeholder `firebase_options.dart` with `projectId: wamu-unconfigured`).

Private beta Android/iOS:

```bash
cd wamu-mobile
# Creates lib/firebase_options.dart + android/app/google-services.json (+ iOS plist)
flutterfire configure --project=YOUR_FIREBASE_PROJECT

# Confirm projectId is no longer wamu-unconfigured (PushBootstrap auto-enables)
grep projectId lib/firebase_options.dart
```

Also set backend `FCM_SERVER_KEY` (legacy server key) in `infrastructure/.env.staging` and restart the API/worker. Order status updates enqueue the same Celery push task as chat (generic body only).

After configure:

- `PushRegistration` watches auth → `getToken()` → `PushTokenRepository.register`
- Token refresh is re-registered automatically
- Foreground `FirebaseMessaging.onMessage` refreshes the commerce inbox (shell snackbar/badge)
- `onMessageOpenedApp` also refreshes so tapped notifications surface in-app
- Logout best-effort deletes the token on the API
- `google-services` Gradle plugin applies only if `android/app/google-services.json` exists

## Mute

`ConversationMember.muted=true` → no push enqueue (in-app Notification row still created).

## Non-goals (v1)

- Firebase Admin HTTP v1 service-account auth (legacy key is enough for staging)  
- APNs direct (use FCM for iOS)  
- Rich reply / media in notification  
- Signal E2EE ciphertext in push  
