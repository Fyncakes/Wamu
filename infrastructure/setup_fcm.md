# Firebase / FCM setup (rider + chat push)

Phone OS notifications need a Firebase project. Web Chrome demos keep working without this (in-app inbox only).

## 1. Create Firebase project

1. https://console.firebase.google.com → Add project → **Wamu** (or reuse existing)
2. Add an **Android** app with package **`ug.wamu.wamu_mobile`**
3. Download `google-services.json` → place at:
   `wamu-mobile/android/app/google-services.json`

Or run the helper (after the JSON is downloaded):

```bash
./infrastructure/setup_fcm.sh
```
4. Project settings → Cloud Messaging → copy **Server key** (legacy) or enable legacy API

## 2. FlutterFire

Existing project id: **`wamu-f7877`**. Do **not** create another project.

```bash
# google-services.json already in android/app/ → this writes firebase_options.dart
./infrastructure/setup_fcm.sh
```

If `flutterfire` asks to create a project, **Ctrl+C** — the helper no longer needs the Firebase CLI.

## 3. Backend

```bash
# wamu-backend/.env and/or infrastructure/.env.staging
FCM_SERVER_KEY=your_legacy_server_key_here
```

Restart API + Celery worker (worker required for push enqueue).

## 4. Rebuild APK

```bash
./infrastructure/build_phone_apk.sh
# After demo tunnel is up, optional:
# API_BASE_URL="$(cat dist/DEMO_URL.txt)/api/v1" ./infrastructure/build_phone_apk.sh
```

## 5. Verify

1. Install APK, login as rider, grant notification permission
2. Place an order that creates a delivery job
3. Rider phone should wake with a generic “Wamu” data push; in-app commerce inbox shows the job

See also: `documentation/PUSH_NOTIFICATIONS.md`
