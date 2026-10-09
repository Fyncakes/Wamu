import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Coarse network class for Storage & data auto-download rules.
enum WamuNetworkKind { wifi, mobile, none }

final connectivityListProvider = StreamProvider<List<ConnectivityResult>>((ref) {
  return Connectivity().onConnectivityChanged;
});

final networkKindProvider = Provider<WamuNetworkKind>((ref) {
  final async = ref.watch(connectivityListProvider);
  final results = async.valueOrNull ?? const <ConnectivityResult>[];
  if (results.isEmpty || results.every((r) => r == ConnectivityResult.none)) {
    return WamuNetworkKind.none;
  }
  if (results.contains(ConnectivityResult.wifi) ||
      results.contains(ConnectivityResult.ethernet) ||
      results.contains(ConnectivityResult.vpn)) {
    return WamuNetworkKind.wifi;
  }
  if (results.contains(ConnectivityResult.mobile)) {
    return WamuNetworkKind.mobile;
  }
  // Browser / unknown → treat as Wi‑Fi (desktop Chrome demo)
  return WamuNetworkKind.wifi;
});
