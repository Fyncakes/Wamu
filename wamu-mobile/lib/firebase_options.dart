// Generated from android/app/google-services.json (project wamu-f7877).
// ignore_for_file: lines_longer_than_80_chars, avoid_classes_with_only_static_members

import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static const String _placeholderProjectId = 'wamu-unconfigured';

  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      return web;
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      case TargetPlatform.macOS:
        return macos;
      default:
        return android;
    }
  }

  static bool get isConfigured =>
      currentPlatform.projectId != _placeholderProjectId;

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyD8TLb2oaRM3xYVV5AjFUghT-EQCKW6er4',
    appId: '1:475644425732:android:459e6079a72571abb8e751',
    messagingSenderId: '475644425732',
    projectId: 'wamu-f7877',
    authDomain: 'wamu-f7877.firebaseapp.com',
    storageBucket: 'wamu-f7877.firebasestorage.app',
  );

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyD8TLb2oaRM3xYVV5AjFUghT-EQCKW6er4',
    appId: '1:475644425732:android:459e6079a72571abb8e751',
    messagingSenderId: '475644425732',
    projectId: 'wamu-f7877',
    storageBucket: 'wamu-f7877.firebasestorage.app',
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'AIzaSyD8TLb2oaRM3xYVV5AjFUghT-EQCKW6er4',
    appId: '1:475644425732:android:459e6079a72571abb8e751',
    messagingSenderId: '475644425732',
    projectId: 'wamu-f7877',
    storageBucket: 'wamu-f7877.firebasestorage.app',
    iosBundleId: 'ug.wamu.wamuMobile',
  );

  static const FirebaseOptions macos = FirebaseOptions(
    apiKey: 'AIzaSyD8TLb2oaRM3xYVV5AjFUghT-EQCKW6er4',
    appId: '1:475644425732:android:459e6079a72571abb8e751',
    messagingSenderId: '475644425732',
    projectId: 'wamu-f7877',
    storageBucket: 'wamu-f7877.firebasestorage.app',
    iosBundleId: 'ug.wamu.wamuMobile',
  );
}
