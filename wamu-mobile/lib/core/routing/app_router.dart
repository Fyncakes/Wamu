import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/admin/admin_hub_screen.dart';
import '../../features/ai/ai_search_screen.dart';
import '../../features/auth/account_qr_screen.dart';
import '../../features/auth/auth_provider.dart';
import '../../features/auth/login_screen.dart';
import '../../features/auth/otp_screen.dart';
import '../../features/auth/profile_setup_screen.dart';
import '../../features/auth/server_setup_screen.dart';
import '../../features/auth/splash_screen.dart';
import '../../core/server_config.dart';
import '../../features/business_owner/business_dashboard_screens.dart';
import '../../features/business_owner/business_owner_screen.dart';
import '../../features/business_owner/manage_videos_screen.dart';
import '../../features/business_owner/payout_settings_screen.dart';
import '../../features/businesses/business_detail_screen.dart';
import '../../features/calls/calls_screen.dart';
import '../../features/cart/cart_screen.dart';
import '../../features/chat/communities_screen.dart';
import '../../features/chat/messages_screen.dart';
import '../../features/chat/status_screen.dart';
import '../../features/discover/discover_feed_screen.dart';
import '../../features/home/home_screen.dart';
import '../../features/move/delivery_workbench_screen.dart';
import '../../features/move/rider_dashboard_screen.dart';
import '../../features/move/rider_live_map_screen.dart';
import '../../features/move/rider_onboarding_screen.dart';
import '../../features/move/wamu_move_screen.dart';
import '../../features/orders/orders_screen.dart';
import '../../features/products/product_detail_screen.dart';
import '../../features/profile/appearance_screen.dart';
import '../../features/profile/customer_dashboard_screen.dart';
import '../../features/profile/favorites_screen.dart';
import '../../features/profile/edit_profile_screen.dart';
import '../../features/profile/help_screen.dart';
import '../../features/profile/notification_settings_screen.dart';
import '../../features/profile/notifications_screen.dart';
import '../../features/profile/privacy_screen.dart';
import '../../features/profile/profile_screen.dart';
import '../../features/profile/settings_screen.dart';
import '../../features/profile/storage_data_screen.dart';
import '../../features/search/search_screen.dart';
import '../../shared/widgets/main_shell.dart';
import '../../shared/widgets/main_tab_swipe.dart';

/// Shell: Videos | Chats | Shops | Orders | You
final appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/splash',
    refreshListenable: _AuthRefreshListenable(ref),
    redirect: (context, state) {
      final auth = ref.read(authProvider);
      final loc = state.matchedLocation;
      final isServerSetup = loc == '/server-setup';
      final isAuthRoute =
          loc == '/login' || loc == '/otp' || loc.startsWith('/otp') || isServerSetup;
      final isSplash = loc == '/splash';

      // First launch on a physical phone: must pick PC / tunnel URL once.
      if (ServerConfig.needsSetup && !isServerSetup && !isSplash) {
        return '/server-setup';
      }

      if (auth.status == AuthStatus.unknown) {
        return isSplash ? null : '/splash';
      }
      if (auth.status == AuthStatus.unauthenticated) {
        return isAuthRoute || loc == '/login' ? null : '/login';
      }
      if (auth.status == AuthStatus.needsProfile) {
        return loc == '/profile-setup' ? null : '/profile-setup';
      }
      // Allow changing PC server while logged in
      if (isServerSetup) return null;
      if (isAuthRoute || isSplash || loc == '/login' || loc == '/profile-setup') {
        return '/home';
      }
      return null;
    },
    routes: [
      GoRoute(path: '/splash', builder: (_, __) => const SplashScreen()),
      GoRoute(path: '/login', builder: (_, __) => const LoginScreen()),
      GoRoute(
        path: '/server-setup',
        builder: (context, state) {
          final fromSettings = state.extra == true;
          return ServerSetupScreen(fromSettings: fromSettings);
        },
      ),
      GoRoute(
        path: '/otp',
        builder: (context, state) {
          final phone = state.extra as String? ?? '';
          return OtpScreen(phone: phone);
        },
      ),
      GoRoute(path: '/profile-setup', builder: (_, __) => const ProfileSetupScreen()),
      StatefulShellRoute(
        builder: (context, state, navigationShell) =>
            MainShell(navigationShell: navigationShell),
        navigatorContainerBuilder: (context, navigationShell, children) {
          return MainTabSwipe(
            currentIndex: navigationShell.currentIndex,
            onIndexChanged: (i) => navigationShell.goBranch(i),
            children: children,
          );
        },
        branches: [
          StatefulShellBranch(routes: [
            GoRoute(path: '/home', builder: (_, __) => const DiscoverFeedScreen()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: '/chats', builder: (_, __) => const MessagesScreen()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: '/shops', builder: (_, __) => const HomeScreen()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: '/orders', builder: (_, __) => const OrdersScreen()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: '/settings', builder: (_, __) => const SettingsScreen()),
          ]),
        ],
      ),
      // Aliases / deferred surfaces
      GoRoute(path: '/discover', redirect: (_, __) => '/home'),
      GoRoute(path: '/videos', redirect: (_, __) => '/home'),
      GoRoute(path: '/discover-catalog', redirect: (_, __) => '/shops'),
      GoRoute(path: '/messages', redirect: (_, __) => '/chats'),
      GoRoute(path: '/updates', redirect: (_, __) => '/status'),
      GoRoute(path: '/you', redirect: (_, __) => '/settings'),
      GoRoute(path: '/move', redirect: (_, __) => '/deliveries'),
      GoRoute(path: '/deliveries', builder: (_, __) => const DeliveryWorkbenchScreen()),
      GoRoute(path: '/rides', builder: (_, __) => const WamuMoveScreen()),
      GoRoute(path: '/status', builder: (_, __) => const StatusScreen()),
      GoRoute(path: '/communities', builder: (_, __) => const CommunitiesScreen()),
      GoRoute(path: '/calls', builder: (_, __) => const CallsScreen()),
      GoRoute(path: '/search', builder: (_, __) => const SearchScreen()),
      GoRoute(path: '/profile', builder: (_, __) => const ProfileScreen()),
      GoRoute(
        path: '/business/:id',
        builder: (_, state) => BusinessDetailScreen(
          businessId: state.pathParameters['id']!,
          orderId: state.uri.queryParameters['orderId'],
        ),
      ),
      GoRoute(
        path: '/product/:id',
        builder: (_, state) => ProductDetailScreen(productId: state.pathParameters['id']!),
      ),
      GoRoute(path: '/cart', builder: (_, __) => const CartScreen()),
      GoRoute(
        path: '/orders/:id',
        builder: (_, state) => OrderDetailScreen(orderId: state.pathParameters['id']!),
      ),
      GoRoute(path: '/notifications', builder: (_, __) => const NotificationsScreen()),
      GoRoute(
        path: '/notification-settings',
        builder: (_, __) => const NotificationSettingsScreen(),
      ),
      GoRoute(path: '/appearance', builder: (_, __) => const AppearanceScreen()),
      GoRoute(path: '/privacy', builder: (_, __) => const PrivacyScreen()),
      GoRoute(path: '/storage-data', builder: (_, __) => const StorageDataScreen()),
      GoRoute(path: '/help', builder: (_, __) => const HelpScreen()),
      GoRoute(path: '/edit-profile', builder: (_, __) => const EditProfileScreen()),
      GoRoute(path: '/account-qr', builder: (_, __) => const AccountQrScreen()),
      GoRoute(path: '/favorites', builder: (_, __) => const FavoritesScreen()),
      GoRoute(path: '/me', builder: (_, __) => const CustomerDashboardScreen()),
      GoRoute(path: '/me/payments', builder: (_, __) => const PaymentsWalletScreen()),
      GoRoute(path: '/me/following', builder: (_, __) => const FollowingScreen()),
      GoRoute(path: '/me/reviews', builder: (_, __) => const MyReviewsScreen()),
      GoRoute(path: '/me/deliveries', builder: (_, __) => const CustomerDeliveryHistoryScreen()),
      GoRoute(path: '/admin', builder: (_, __) => const AdminHubScreen()),
      GoRoute(path: '/rider', builder: (_, __) => const RiderDashboardScreen()),
      GoRoute(path: '/rider/onboarding', builder: (_, __) => const RiderOnboardingScreen()),
      GoRoute(path: '/rider/vehicle', builder: (_, __) => const RiderVehicleScreen()),
      GoRoute(
        path: '/rider/live-map',
        builder: (_, state) => RiderLiveMapScreen(
          deliveryId: state.uri.queryParameters['deliveryId'],
        ),
      ),
      GoRoute(path: '/chats/new', builder: (_, __) => const NewChatScreen()),
      GoRoute(
        path: '/chat/:id',
        builder: (_, state) => ChatScreen(conversationId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/ai',
        builder: (_, state) {
          final extra = state.extra;
          final q = extra is String ? extra : null;
          return AiSearchScreen(initialQuery: q);
        },
      ),
      GoRoute(path: '/business-owner', builder: (_, __) => const BusinessOwnerScreen()),
      GoRoute(path: '/business-owner/create', builder: (_, __) => const CreateBusinessScreen()),
      GoRoute(path: '/business-owner/products', builder: (_, __) => const ManageProductsScreen()),
      GoRoute(path: '/business-owner/orders', builder: (_, __) => const ManageOrdersScreen()),
      GoRoute(path: '/business-owner/reviews', builder: (_, __) => const ManageReviewsScreen()),
      GoRoute(path: '/business-owner/payouts', builder: (_, __) => const PayoutSettingsScreen()),
      GoRoute(path: '/business-owner/videos', builder: (_, __) => const ManageVideosScreen()),
      GoRoute(path: '/business-owner/overview', builder: (_, __) => const BusinessOverviewScreen()),
      GoRoute(path: '/business-owner/customers', builder: (_, __) => const BusinessCustomersScreen()),
      GoRoute(path: '/business-owner/staff', builder: (_, __) => const BusinessStaffScreen()),
      GoRoute(path: '/business-owner/settings', builder: (_, __) => const BusinessSettingsScreen()),
      GoRoute(path: '/business-owner/promotions', builder: (_, __) => const BusinessPromotionsScreen()),
    ],
  );
});

class _AuthRefreshListenable extends ChangeNotifier {
  _AuthRefreshListenable(this.ref) {
    ref.listen<AuthState>(authProvider, (_, __) => notifyListeners());
  }

  final Ref ref;
}
