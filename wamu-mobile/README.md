# WAMU Mobile — Uganda Super App

**Connect. Discover. Do More.**

Flutter client for the WAMU marketplace super app, targeting Android, iOS, and web.

## Prerequisites

- [Flutter SDK](https://docs.flutter.dev/get-started/install) (3.13+)
- Android Studio / Xcode for emulators
- WAMU backend running locally on port `8000`

## Setup

```bash
export PATH="$HOME/flutter/bin:$PATH"
cd /home/the-kola-s/Documents/WAMU/wamu-mobile
flutter pub get
```

## API Configuration

Base URL is resolved in `lib/core/config.dart`:

| Platform | Host | URL |
|----------|------|-----|
| Android emulator | `10.0.2.2` | `http://10.0.2.2:8000/api/v1` |
| iOS simulator / Web / Desktop | `localhost` | `http://localhost:8000/api/v1` |

Start the backend before running the app. Android cleartext HTTP is enabled for local development.

## Run

### Android

```bash
flutter devices          # list emulators
flutter run            # launches on connected device/emulator
```

## Physical phone (same Wi‑Fi)

1. Backend must listen on all interfaces:  
   `uvicorn app.main:app --host 0.0.0.0 --port 8000`
2. Build APK pointed at your PC’s LAN IP:

```bash
export JAVA_HOME=/path/to/jdk-17   # if needed
export PATH="$JAVA_HOME/bin:$HOME/flutter/bin:$PATH"
cd wamu-mobile
flutter build apk --release --dart-define=API_HOST=192.168.x.x
```

APK: `build/app/outputs/flutter-apk/app-release.apk` (also copied to `dist/wamu-phone.apk` when using the local build helper).

3. On Android: enable **Install unknown apps**, transfer the APK (USB, Drive, or `adb install`), open it.
4. Login OTP mock code: **123456** (while `OTP_MOCK_MODE=true`).

Phone and PC must be on the same Wi‑Fi; if login fails, confirm `http://YOUR_LAN_IP:8000/api/v1/health` opens in the phone browser.

```bash
cd ios && pod install && cd ..
flutter run -d ios
```

### Web

```bash
flutter run -d chrome
```

## Auth Flow (Dev)

1. Enter a Ugandan phone number (`+256…`)
2. Request OTP → backend `POST /auth/request-otp`
3. Enter OTP — mock code **`123456`** works in development
4. Complete profile (name) if first login
5. Land on Home with bottom navigation

## Project Structure

```
lib/
├── main.dart                 # App entry, ProviderScope, MaterialApp.router
├── core/
│   ├── config.dart           # API base URL, constants
│   ├── network/api_client.dart
│   ├── storage/secure_storage.dart
│   ├── theme/app_theme.dart
│   └── routing/app_router.dart
├── features/
│   ├── auth/                 # Login, OTP, profile setup
│   ├── home/                 # Categories, nearby, popular
│   ├── search/
│   ├── businesses/
│   ├── products/
│   ├── cart/
│   ├── orders/
│   ├── chat/
│   ├── profile/
│   ├── ai/
│   └── business_owner/
└── shared/
    ├── widgets/
    ├── models/
    └── utils/
```

## Bottom Navigation

| Tab | Route | Screen |
|-----|-------|--------|
| Home | `/home` | Marketplace feed |
| Search | `/search` | Product search |
| Orders | `/orders` | Order history |
| Messages | `/messages` | Chat conversations |
| Profile | `/profile` | Account & settings |

## Analyze & Test

```bash
flutter analyze
flutter test
```

## Theme

- Primary: deep green `#0B6E4F`
- Accents: warm sand `#F5E6D3`
- Fonts: **Outfit** (UI) + **Fraunces** (brand/display) via Google Fonts
