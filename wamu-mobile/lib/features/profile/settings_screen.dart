import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/server_config.dart';
import '../../core/storage/secure_storage.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/widgets/wamu_network_image.dart';
import '../auth/auth_provider.dart';

/// You tab — identity-first settings hub.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  static const _dataSaverKey = 'wamu_data_saver';
  bool _dataSaver = true;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    final raw = await ref.read(secureStorageProvider).read(_dataSaverKey);
    setState(() {
      _dataSaver = raw != '0';
      _loaded = true;
    });
  }

  Future<void> _setDataSaver(bool value) async {
    setState(() => _dataSaver = value);
    await ref.read(secureStorageProvider).write(_dataSaverKey, value ? '1' : '0');
  }

  Future<void> _openLiveDemo() async {
    if (kIsWeb) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Use the browser refresh button (or pull down) after a PC rebuild.'),
        ),
      );
      return;
    }
    final uri = Uri.parse(ServerConfig.mediaOrigin);
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Open Chrome: ${ServerConfig.mediaOrigin}')),
      );
    }
  }

  String _rolesSubtitle(dynamic user) {
    if (user == null) return 'Buy · Business · Deliver';
    final parts = <String>[];
    if (user.wantsToBuy == true) parts.add('Buy');
    if (user.ownsBusiness == true || user.isBusinessOwner == true) parts.add('Business');
    if (user.wantsToRide == true) parts.add('Deliver');
    return parts.isEmpty ? 'Tap to enable roles' : parts.join(' · ');
  }

  Future<void> _editCapabilities(BuildContext context) async {
    final user = ref.read(authProvider).user;
    if (user == null) return;
    var buy = user.wantsToBuy;
    var business = user.ownsBusiness || user.isBusinessOwner;
    var ride = user.wantsToRide;
    final ok = await showModalBottomSheet<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModal) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 12, 8, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const ListTile(
                      title: Text(
                        'One account, many roles',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                      subtitle: Text('Buy, sell, or deliver on the same Wamu account'),
                    ),
                    SwitchListTile(
                      title: const Text('I want to buy'),
                      value: buy,
                      activeThumbColor: Colors.black,
                      activeTrackColor: AppTheme.accentGreen,
                      onChanged: (v) => setModal(() => buy = v),
                    ),
                    SwitchListTile(
                      title: const Text('I own a business'),
                      value: business,
                      activeThumbColor: Colors.black,
                      activeTrackColor: AppTheme.accentGreen,
                      onChanged: (v) => setModal(() => business = v),
                    ),
                    SwitchListTile(
                      title: const Text('I deliver for Wamu'),
                      subtitle: const Text('Rider network — delivery first'),
                      value: ride,
                      activeThumbColor: Colors.black,
                      activeTrackColor: AppTheme.accentGreen,
                      onChanged: (v) => setModal(() => ride = v),
                    ),
                    const SizedBox(height: 8),
                    FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppTheme.accentGreen,
                        foregroundColor: Colors.black,
                        minimumSize: const Size(double.infinity, 48),
                      ),
                      child: const Text('Save', style: TextStyle(fontWeight: FontWeight.w800)),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
    if (ok != true || !mounted) return;
    try {
      await ref.read(authProvider.notifier).updateProfileCapabilities(
            wantsToBuy: buy,
            ownsBusiness: business,
            wantsToRide: ride,
          );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Roles updated')),
        );
        setState(() {});
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final user = auth.user;
    final name = (user?.name.isNotEmpty == true) ? user!.name : 'Wamu user';
    final phone = user?.phone ?? '+256';
    final bio = (user?.bio?.trim().isNotEmpty == true)
        ? user!.bio!.trim()
        : 'Hey there! I am using Wamu';
    final letter = name.trim().isNotEmpty ? name.trim()[0].toUpperCase() : 'W';
    final dark = Theme.of(context).brightness == Brightness.dark;
    final hasAvatar = user?.avatarUrl != null && user!.avatarUrl!.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('You'),
        actions: const [],
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(0, 8, 0, 32),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                  child: InkWell(
                    onTap: () => context.push('/edit-profile'),
                    borderRadius: BorderRadius.circular(16),
                    child: Column(
                      children: [
                        Stack(
                          children: [
                            CircleAvatar(
                              radius: 44,
                              backgroundColor: AppTheme.accentGreen,
                              child: hasAvatar
                                  ? ClipOval(
                                      child: WamuNetworkImage(
                                        imageUrl: user!.avatarUrl,
                                        width: 88,
                                        height: 88,
                                      ),
                                    )
                                  : Text(
                                      letter,
                                      style: const TextStyle(
                                        color: Colors.black,
                                        fontSize: 34,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                            ),
                            Positioned(
                              right: 0,
                              bottom: 0,
                              child: Material(
                                color: AppTheme.accentGreen,
                                shape: const CircleBorder(),
                                child: InkWell(
                                  customBorder: const CircleBorder(),
                                  onTap: () => context.push('/edit-profile'),
                                  child: const Padding(
                                    padding: EdgeInsets.all(6),
                                    child: Icon(Icons.add, size: 16, color: Colors.black),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text(name, style: Theme.of(context).textTheme.titleLarge),
                        const SizedBox(height: 4),
                        Text(phone, style: Theme.of(context).textTheme.bodyMedium),
                        const SizedBox(height: 2),
                        Text(bio, style: Theme.of(context).textTheme.bodySmall),
                        const SizedBox(height: 10),
                        OutlinedButton.icon(
                          onPressed: () => context.push('/account-qr'),
                          icon: const Icon(Icons.qr_code_2, size: 18),
                          label: const Text('My QR code'),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Tap photo to edit profile',
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                color: AppTheme.accentGreen,
                              ),
                        ),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    'Workspaces',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: SizedBox(
                    height: 104,
                    child: Row(
                      children: [
                        Expanded(
                          child: _RoleCard(
                            icon: Icons.shopping_bag_outlined,
                            title: 'Customer',
                            subtitle: 'Shop · track',
                            onTap: () => context.push('/me'),
                          ),
                        ),
                        Expanded(
                          child: _RoleCard(
                            icon: Icons.storefront_outlined,
                            title: 'Merchant',
                            subtitle: user?.isBusinessOwner == true
                                ? 'Your shop'
                                : 'Start selling',
                            onTap: () => context.push(
                              user?.isBusinessOwner == true
                                  ? '/business-owner'
                                  : '/business-owner/create',
                            ),
                          ),
                        ),
                        Expanded(
                          child: _RoleCard(
                            icon: Icons.delivery_dining,
                            title: 'Rider',
                            subtitle: user?.wantsToRide == true
                                ? 'Jobs, verification & earnings'
                                : 'Become a Wamu Rider',
                            onTap: () => context.push(
                              user?.wantsToRide == true
                                  ? '/rider'
                                  : '/rider/onboarding',
                            ),
                          ),
                        ),
                        if (user?.isAdmin == true)
                          Expanded(
                            child: _RoleCard(
                              icon: Icons.admin_panel_settings_outlined,
                              title: 'Admin',
                              subtitle: 'Phone console',
                              highlight: true,
                              onTap: () => context.push('/admin'),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                const Divider(height: 1),
                _YouTile(
                  icon: Icons.key_outlined,
                  title: 'Account',
                  subtitle: 'Name, photo, about',
                  onTap: () => context.push('/edit-profile'),
                ),
                _YouTile(
                  icon: Icons.qr_code_2,
                  title: 'My QR code',
                  subtitle: 'Sign in on another phone without sharing your password',
                  onTap: () => context.push('/account-qr'),
                ),
                _YouTile(
                  icon: Icons.dns_outlined,
                  title: 'Wamu server',
                  subtitle: 'Scan the computer /connect QR or paste the API link',
                  onTap: () => context.push('/server-setup', extra: true),
                ),
                _YouTile(
                  icon: Icons.refresh,
                  title: 'Live updates',
                  subtitle: kIsWeb
                      ? 'After a PC web rebuild, refresh this page'
                      : 'Open Chrome on this phone and refresh — no APK rebuild',
                  onTap: _openLiveDemo,
                ),
                _YouTile(
                  icon: Icons.lock_outline,
                  title: 'Privacy',
                  subtitle: 'Last seen, online, read receipts',
                  onTap: () => context.push('/privacy'),
                ),
                _YouTile(
                  icon: Icons.palette_outlined,
                  title: 'Appearance',
                  subtitle: 'Chat theme, dark or white app theme',
                  onTap: () => context.push('/appearance'),
                ),
                _YouTile(
                  icon: Icons.notifications_outlined,
                  title: 'Notifications',
                  subtitle: 'Message, group & call alerts',
                  onTap: () => context.push('/notification-settings'),
                ),
                _YouTile(
                  icon: Icons.storage_outlined,
                  title: 'Storage and data',
                  subtitle: 'Network usage, auto-download',
                  onTap: () => context.push('/storage-data'),
                ),
                _YouTile(
                  icon: Icons.data_saver_on,
                  title: 'Data saver',
                  subtitle: 'Compress media for MTN/Airtel 3G',
                  trailing: Switch(
                    value: _dataSaver,
                    activeThumbColor: Colors.black,
                    activeTrackColor: AppTheme.accentGreen,
                    onChanged: _setDataSaver,
                  ),
                ),
                Divider(
                  height: 24,
                  color: dark ? null : const Color(0xFFE9EDEF),
                ),
                _YouTile(
                  icon: Icons.dashboard_customize_outlined,
                  title: 'Customer dashboard',
                  subtitle: 'Payments, following, reviews, deliveries',
                  onTap: () => context.push('/me'),
                ),
                _YouTile(
                  icon: Icons.search,
                  title: 'Search',
                  subtitle: 'Find shops and products nearby',
                  onTap: () => context.push('/search'),
                ),
                _YouTile(
                  icon: Icons.storefront_outlined,
                  title: 'Nearby shops',
                  subtitle: 'Browse merchants and products',
                  onTap: () => context.go('/shops'),
                ),
                _YouTile(
                  icon: Icons.delivery_dining,
                  title: 'Deliveries / Rider',
                  subtitle: user?.wantsToRide == true
                      ? 'Jobs, verification & earnings'
                      : 'Become a Wamu Rider — register & verify',
                  onTap: () => context.push(
                    user?.wantsToRide == true ? '/rider' : '/rider/onboarding',
                  ),
                ),
                _YouTile(
                  icon: Icons.directions_car_outlined,
                  title: 'Request a ride',
                  subtitle: 'Passenger Move — Kampala boda',
                  onTap: () => context.push('/rides'),
                ),
                _YouTile(
                  icon: Icons.groups_outlined,
                  title: 'Communities',
                  subtitle: 'Join local groups and channels',
                  onTap: () => context.push('/communities'),
                ),
                _YouTile(
                  icon: Icons.shopping_cart_outlined,
                  title: 'Cart',
                  subtitle: 'Checkout and MoMo pay',
                  onTap: () => context.push('/cart'),
                ),
                if (user?.ownsBusiness != true && user?.isBusinessOwner != true)
                  _YouTile(
                    icon: Icons.storefront_outlined,
                    title: 'Sell on Wamu',
                    subtitle: 'Create a shop and list products',
                    onTap: () => context.push('/business-owner/create'),
                  ),
                _YouTile(
                  icon: Icons.favorite_outline,
                  title: 'Favourites',
                  subtitle: 'Saved shops and products',
                  onTap: () => context.push('/favorites'),
                ),
                if (user?.ownsBusiness == true || user?.isBusinessOwner == true)
                  _YouTile(
                    icon: Icons.business_center_outlined,
                    title: 'My business',
                    subtitle: 'Products, stock, and orders',
                    onTap: () => context.push('/business-owner'),
                  ),
                _YouTile(
                  icon: Icons.tune,
                  title: 'Roles on this account',
                  subtitle: _rolesSubtitle(user),
                  onTap: () => _editCapabilities(context),
                ),
                if (user?.isAdmin == true)
                  _YouTile(
                    icon: Icons.admin_panel_settings_outlined,
                    title: 'Admin console',
                    subtitle: 'Stats, approve riders & shops on phone',
                    onTap: () => context.push('/admin'),
                  ),
                _YouTile(
                  icon: Icons.smart_toy_outlined,
                  title: 'Ask Wamu',
                  subtitle: 'AI search across Uganda',
                  onTap: () => context.push('/ai'),
                ),
                _YouTile(
                  icon: Icons.help_outline,
                  title: 'Help',
                  subtitle: 'FAQ, contact us, app info',
                  onTap: () => context.push('/help'),
                ),
                const Divider(height: 24),
                ListTile(
                  leading: const Icon(Icons.logout, color: Colors.redAccent),
                  title: const Text('Log out', style: TextStyle(color: Colors.redAccent)),
                  onTap: () async {
                    await ref.read(authProvider.notifier).logout();
                    if (context.mounted) context.go('/login');
                  },
                ),
              ],
            ),
    );
  }
}

class _YouTile extends StatelessWidget {
  const _YouTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      leading: CircleAvatar(
        radius: 22,
        backgroundColor: dark ? AppTheme.messengerElevated : const Color(0xFFF0F2F5),
        child: Icon(icon, color: AppTheme.accentGreen, size: 22),
      ),
      title: Text(title),
      subtitle: Text(
        subtitle,
        style: TextStyle(
          color: dark ? const Color(0xFFB8C0C4) : const Color(0xFF667781),
          fontSize: 13,
          height: 1.3,
        ),
      ),
      isThreeLine: subtitle.length > 36,
      trailing: trailing ??
          (onTap != null
              ? Icon(
                  Icons.chevron_right,
                  color: dark ? AppTheme.messengerMuted : const Color(0xFF667781),
                  size: 20,
                )
              : null),
      onTap: onTap,
    );
  }
}

class _RoleCard extends StatelessWidget {
  const _RoleCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.highlight = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final bg = highlight
        ? AppTheme.accentGreen
        : (dark ? AppTheme.messengerElevated : const Color(0xFFF0F2F5));
    final fg = highlight ? Colors.black : (dark ? Colors.white : Colors.black87);
    final muted = highlight
        ? Colors.black.withValues(alpha: 0.72)
        : (dark ? const Color(0xFFB8C0C4) : const Color(0xFF667781));
    final iconColor = highlight ? Colors.black : AppTheme.accentGreen;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: SizedBox(
            width: double.infinity,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(icon, color: iconColor, size: 22),
                  const Spacer(),
                  Text(
                    title,
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                      color: fg,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.25,
                      fontWeight: FontWeight.w500,
                      color: muted,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
