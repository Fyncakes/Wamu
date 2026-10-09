import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../shared/models/business_model.dart';
import '../../shared/models/category_model.dart';
import '../../shared/models/order_model.dart';
import '../../shared/models/product_model.dart';
import '../../shared/models/review_model.dart';
import '../../shared/utils/order_payment_style.dart';
import '../../shared/utils/order_tracking.dart';
import '../../shared/utils/phone_normalize.dart';
import '../../shared/utils/ugx_formatter.dart';
import '../../shared/widgets/wamu_network_image.dart';
import '../auth/auth_provider.dart';
import '../businesses/favorites_repository.dart';
import '../home/catalog_repository.dart';
import '../move/riders_repository.dart';
import '../orders/orders_repository.dart';
import '../../core/network/api_client.dart';
import 'owner_products_repository.dart';

/// Business owner hub.
class BusinessOwnerScreen extends ConsumerStatefulWidget {
  const BusinessOwnerScreen({super.key});

  @override
  ConsumerState<BusinessOwnerScreen> createState() => _BusinessOwnerScreenState();
}

class _BusinessOwnerScreenState extends ConsumerState<BusinessOwnerScreen> {
  String? _verification;
  String? _bizName;
  bool _loading = true;
  Timer? _statusPoll;

  @override
  void initState() {
    super.initState();
    _loadMine();
    _statusPoll = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted) return;
      _loadMine(silent: true);
    });
  }

  @override
  void dispose() {
    _statusPoll?.cancel();
    super.dispose();
  }

  Future<void> _loadMine({bool silent = false}) async {
    try {
      final response = await ref.read(apiClientProvider).get('/businesses/mine');
      final list = (response.data as List).cast<Map<String, dynamic>>();
      if (list.isNotEmpty) {
        _bizName = list.first['name']?.toString();
        _verification = list.first['verification_status']?.toString();
      }
    } catch (_) {
      // Hub still usable without banner.
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final pending = (_verification ?? '').toUpperCase() == 'PENDING';
    final verified = (_verification ?? '').toUpperCase() == 'VERIFIED';

    return Scaffold(
      appBar: AppBar(title: const Text('Business Owner')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            _bizName == null ? 'Manage your WAMU storefront' : _bizName!,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          Text(
            'List products, chat with customers, and fulfill orders.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          if (!_loading && pending) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.orange.shade300),
              ),
              child: const Text(
                'Verification pending — you can still add products and take orders. '
                'Admin will verify your business for the Kampala pilot.',
              ),
            ),
          ],
          if (!_loading && verified) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(Icons.verified, color: Colors.green.shade700, size: 18),
                const SizedBox(width: 6),
                Text(
                  'Verified on Wamu',
                  style: TextStyle(
                    color: Colors.green.shade700,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 24),
          _OwnerTile(
            icon: Icons.insights_outlined,
            title: 'Sales report',
            subtitle: 'GMV, paid volume, earnings, order mix',
            onTap: () => context.push('/business-owner/overview'),
          ),
          _OwnerTile(
            icon: Icons.add_business,
            title: 'Create business',
            subtitle: 'Register a Kampala storefront',
            onTap: () => context.push('/business-owner/create'),
          ),
          _OwnerTile(
            icon: Icons.inventory_2,
            title: 'Manage products',
            subtitle: 'Add, edit, stock, and photos',
            onTap: () => context.push('/business-owner/products'),
          ),
          _OwnerTile(
            icon: Icons.receipt_long,
            title: 'Manage orders',
            subtitle: 'Confirm, reject, and fulfill orders',
            onTap: () => context.push('/business-owner/orders'),
          ),
          _OwnerTile(
            icon: Icons.people_outline,
            title: 'Customers',
            subtitle: 'Buyers who ordered from you',
            onTap: () => context.push('/business-owner/customers'),
          ),
          _OwnerTile(
            icon: Icons.badge_outlined,
            title: 'Staff / accounts',
            subtitle: 'Invite helpers by phone',
            onTap: () => context.push('/business-owner/staff'),
          ),
          _OwnerTile(
            icon: Icons.reviews_outlined,
            title: 'Customer reviews',
            subtitle: 'Read feedback and reply',
            onTap: () => context.push('/business-owner/reviews'),
          ),
          _OwnerTile(
            icon: Icons.videocam_outlined,
            title: 'My Videos',
            subtitle: 'Publish, manage, or delete shop clips',
            onTap: () => context.push('/business-owner/videos'),
          ),
          _OwnerTile(
            icon: Icons.campaign_outlined,
            title: 'Promotions',
            subtitle: 'Storefront promo banner',
            onTap: () => context.push('/business-owner/promotions'),
          ),
          _OwnerTile(
            icon: Icons.chat_bubble_outline,
            title: 'Business chat',
            subtitle: 'Message customers in Chats',
            onTap: () => context.go('/chats'),
          ),
          _OwnerTile(
            icon: Icons.settings_outlined,
            title: 'Business settings',
            subtitle: 'Name, phone, description, promo',
            onTap: () => context.push('/business-owner/settings'),
          ),
          _OwnerTile(
            icon: Icons.account_balance_wallet_outlined,
            title: 'Payout settings',
            subtitle: 'MoMo / Airtel number for order disbursements',
            onTap: () => context.push('/business-owner/payouts'),
          ),
        ],
      ),
    );
  }
}

class _OwnerTile extends StatelessWidget {
  const _OwnerTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: Icon(icon, color: Theme.of(context).colorScheme.primary),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}

class CreateBusinessScreen extends ConsumerStatefulWidget {
  const CreateBusinessScreen({super.key});

  @override
  ConsumerState<CreateBusinessScreen> createState() => _CreateBusinessScreenState();
}

class _CreateBusinessScreenState extends ConsumerState<CreateBusinessScreen> {
  final _nameController = TextEditingController();
  final _descController = TextEditingController();
  final _addressController = TextEditingController();
  final _phoneController = TextEditingController(text: '+256');
  final _payoutPhoneController = TextEditingController(text: '+256');
  List<CategoryModel> _categories = [];
  String? _categoryId;
  String _payoutProvider = 'MTN';
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _loadCategories();
  }

  Future<void> _loadCategories() async {
    final cats = await ref.read(catalogRepositoryProvider).getCategories();
    setState(() => _categories = cats);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descController.dispose();
    _addressController.dispose();
    _phoneController.dispose();
    _payoutPhoneController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _loading = true);
    try {
      final phone = _phoneController.text.trim();
      final payoutRaw = _payoutPhoneController.text.trim();
      String? payoutPhone;
      if (payoutRaw.isNotEmpty && payoutRaw != '+256') {
        try {
          payoutPhone = normalizeUgPhone(payoutRaw);
        } catch (_) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Payout phone must be a valid +256 number')),
            );
          }
          return;
        }
      }
      await ref.read(apiClientProvider).post('/businesses', data: {
        'name': _nameController.text.trim(),
        'description': _descController.text.trim(),
        if (_categoryId != null) 'category_id': _categoryId,
        if (RegExp(r'^\+256[0-9]{9}$').hasMatch(phone)) 'phone': phone,
        if (payoutPhone != null) 'payout_phone': payoutPhone,
        if (payoutPhone != null) 'payout_provider': _payoutProvider,
        'location': {
          'address_line': _addressController.text.trim().isEmpty
              ? 'Kampala'
              : _addressController.text.trim(),
          'city': 'Kampala',
          // Kampala beachhead default — nearby Discover requires coordinates.
          'latitude': 0.3476,
          'longitude': 32.5825,
        },
      });
      final auth = ref.read(authProvider);
      final u = auth.user;
      if (u != null) {
        await ref.read(authProvider.notifier).updateProfileCapabilities(
              wantsToBuy: u.wantsToBuy,
              ownsBusiness: true,
              wantsToRide: u.wantsToRide,
            );
      } else {
        await ref.read(authProvider.notifier).refreshMe();
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Business created — add products next')),
        );
        context.go('/business-owner/products');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Create business')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _nameController,
            decoration: const InputDecoration(labelText: 'Business name'),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            value: _categoryId,
            decoration: const InputDecoration(labelText: 'Category'),
            items: _categories
                .map((c) => DropdownMenuItem(value: c.id, child: Text(c.name)))
                .toList(),
            onChanged: (v) => setState(() => _categoryId = v),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _descController,
            decoration: const InputDecoration(labelText: 'Description'),
            maxLines: 3,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _phoneController,
            decoration: const InputDecoration(labelText: 'Business phone (+256…)'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _payoutPhoneController,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(
              labelText: 'Payout phone (MoMo / Airtel)',
              hintText: 'Where order money is disbursed — defaults to business phone',
            ),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            value: _payoutProvider,
            decoration: const InputDecoration(labelText: 'Payout rail'),
            items: const [
              DropdownMenuItem(value: 'MTN', child: Text('MTN MoMo')),
              DropdownMenuItem(value: 'AIRTEL', child: Text('Airtel Money')),
              DropdownMenuItem(value: 'MOCK', child: Text('Test payment')),
            ],
            onChanged: (v) {
              if (v != null) setState(() => _payoutProvider = v);
            },
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _addressController,
            decoration: const InputDecoration(
              labelText: 'Address',
              hintText: 'Ntinda, Kampala',
            ),
          ),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: _loading ? null : _submit,
            child: _loading
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Text('Submit'),
          ),
        ],
      ),
    );
  }
}

class ManageProductsScreen extends ConsumerStatefulWidget {
  const ManageProductsScreen({super.key});

  @override
  ConsumerState<ManageProductsScreen> createState() => _ManageProductsScreenState();
}

class _ManageProductsScreenState extends ConsumerState<ManageProductsScreen> {
  List<BusinessModel> _businesses = [];
  List<ProductModel> _products = [];
  String? _businessId;
  bool _bootstrapping = true;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    setState(() {
      _bootstrapping = true;
      _error = null;
    });
    try {
      final businesses = await ref.read(ownerProductsRepositoryProvider).myBusinesses();
      final businessId = businesses.isNotEmpty ? businesses.first.id : null;
      List<ProductModel> products = [];
      if (businessId != null) {
        products = await ref.read(ownerProductsRepositoryProvider).listProducts(businessId);
      }
      if (!mounted) return;
      setState(() {
        _businesses = businesses;
        _businessId = businessId;
        _products = products;
        _bootstrapping = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _bootstrapping = false;
      });
    }
  }

  Future<void> _reloadProducts() async {
    if (_businessId == null) return;
    setState(() => _loading = true);
    try {
      final products =
          await ref.read(ownerProductsRepositoryProvider).listProducts(_businessId!);
      if (mounted) setState(() => _products = products);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _onBusinessChanged(String? id) async {
    setState(() => _businessId = id);
    await _reloadProducts();
  }

  Future<void> _showEditor({ProductModel? existing}) async {
    if (_businessId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Create a business first')),
      );
      return;
    }

    final nameController = TextEditingController(text: existing?.name ?? '');
    final priceController =
        TextEditingController(text: existing == null ? '' : existing.price.toStringAsFixed(0));
    final descController = TextEditingController(text: existing?.description ?? '');
    final stockController = TextEditingController(
      text: (existing?.stockQuantity ?? 10).toString(),
    );
    var status = existing?.status ?? 'ACTIVE';
    final saving = ValueNotifier(false);
    XFile? pickedImage;
    final existingImageUrl = existing?.imageUrl;

    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
          ),
          child: StatefulBuilder(
            builder: (ctx, setLocal) {
              Future<void> pickPhoto(ImageSource source) async {
                final file = await ImagePicker().pickImage(
                  source: source,
                  maxWidth: 1600,
                  imageQuality: 85,
                );
                if (file == null) return;
                setLocal(() => pickedImage = file);
              }

              return SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      existing == null ? 'Add product' : 'Edit product',
                      style: Theme.of(ctx).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      existing == null
                          ? 'Product photo (required)'
                          : 'Product photo',
                      style: Theme.of(ctx).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 8),
                    AspectRatio(
                      aspectRatio: 16 / 10,
                      child: Material(
                        color: Colors.black12,
                        borderRadius: BorderRadius.circular(12),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: () => pickPhoto(ImageSource.gallery),
                          child: pickedImage != null
                              ? FutureBuilder<Uint8List>(
                                  future: pickedImage!.readAsBytes(),
                                  builder: (context, snap) {
                                    if (!snap.hasData) {
                                      return const Center(
                                        child: CircularProgressIndicator(),
                                      );
                                    }
                                    return Image.memory(
                                      snap.data!,
                                      fit: BoxFit.cover,
                                    );
                                  },
                                )
                              : (existingImageUrl != null &&
                                      existingImageUrl.isNotEmpty)
                                  ? Image.network(
                                      existingImageUrl,
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, __, ___) => const Center(
                                        child: Icon(Icons.cake_outlined, size: 40),
                                      ),
                                    )
                                  : const Center(
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(Icons.add_a_photo_outlined, size: 36),
                                          SizedBox(height: 8),
                                          Text('Tap to upload product photo'),
                                          SizedBox(height: 4),
                                          Text(
                                            'Required — cake, meal, or item photo',
                                            style: TextStyle(fontSize: 12),
                                          ),
                                        ],
                                      ),
                                    ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => pickPhoto(ImageSource.gallery),
                            icon: const Icon(Icons.photo_library_outlined),
                            label: const Text('Gallery'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => pickPhoto(ImageSource.camera),
                            icon: const Icon(Icons.photo_camera_outlined),
                            label: const Text('Camera'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: nameController,
                      decoration: const InputDecoration(labelText: 'Name'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: priceController,
                      decoration: const InputDecoration(labelText: 'Price (UGX)'),
                      keyboardType: TextInputType.number,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: stockController,
                      decoration: const InputDecoration(labelText: 'Stock quantity'),
                      keyboardType: TextInputType.number,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: descController,
                      decoration: const InputDecoration(labelText: 'Description'),
                      maxLines: 2,
                    ),
                    if (existing != null) ...[
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        value: status,
                        decoration: const InputDecoration(labelText: 'Status'),
                        items: const [
                          DropdownMenuItem(value: 'ACTIVE', child: Text('Active')),
                          DropdownMenuItem(value: 'INACTIVE', child: Text('Inactive')),
                          DropdownMenuItem(value: 'OUT_OF_STOCK', child: Text('Out of stock')),
                        ],
                        onChanged: (v) => setLocal(() => status = v ?? status),
                      ),
                    ],
                    const SizedBox(height: 20),
                    ValueListenableBuilder<bool>(
                      valueListenable: saving,
                      builder: (_, busy, __) => ElevatedButton(
                        onPressed: busy
                            ? null
                            : () async {
                                final name = nameController.text.trim();
                                final price =
                                    double.tryParse(priceController.text.trim()) ?? 0;
                                final stock =
                                    int.tryParse(stockController.text.trim()) ?? 0;
                                final desc = descController.text.trim();
                                if (name.isEmpty || price <= 0) {
                                  ScaffoldMessenger.of(ctx).showSnackBar(
                                    const SnackBar(
                                      content: Text('Enter a name and price'),
                                    ),
                                  );
                                  return;
                                }
                                if (existing == null && pickedImage == null) {
                                  ScaffoldMessenger.of(ctx).showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                        'Add a product photo (gallery or camera)',
                                      ),
                                    ),
                                  );
                                  return;
                                }
                                saving.value = true;
                                try {
                                  final repo =
                                      ref.read(ownerProductsRepositoryProvider);
                                  if (existing == null) {
                                    final created = await repo.createProduct(
                                      businessId: _businessId!,
                                      name: name,
                                      price: price,
                                      description: desc,
                                      stockQuantity: stock,
                                    );
                                    await repo.uploadImage(
                                      created.id,
                                      pickedImage!,
                                    );
                                  } else {
                                    await repo.updateProduct(
                                      productId: existing.id,
                                      name: name,
                                      price: price,
                                      description: desc,
                                      stockQuantity: stock,
                                      status: status,
                                    );
                                    if (pickedImage != null) {
                                      await repo.uploadImage(
                                        existing.id,
                                        pickedImage!,
                                      );
                                    }
                                  }
                                  if (ctx.mounted) Navigator.pop(ctx, true);
                                } catch (e) {
                                  if (ctx.mounted) {
                                    ScaffoldMessenger.of(ctx).showSnackBar(
                                      SnackBar(content: Text('$e')),
                                    );
                                  }
                                } finally {
                                  saving.value = false;
                                }
                              },
                        child: busy
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : Text(
                                existing == null ? 'Add product' : 'Save changes',
                              ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );

    nameController.dispose();
    priceController.dispose();
    descController.dispose();
    stockController.dispose();
    saving.dispose();

    if (saved == true) await _reloadProducts();
  }

  Future<void> _pickAndUploadImage(ProductModel product) async {
    final picker = ImagePicker();
    final file = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1600,
      imageQuality: 85,
    );
    if (file == null) return;

    setState(() => _loading = true);
    try {
      await ref.read(ownerProductsRepositoryProvider).uploadImage(product.id, file);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Photo uploaded')),
        );
      }
      await _reloadProducts();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Manage products'),
        actions: [
          if (_businessId != null)
            IconButton(
              tooltip: 'Refresh',
              onPressed: _loading ? null : _reloadProducts,
              icon: const Icon(Icons.refresh),
            ),
        ],
      ),
      floatingActionButton: _businessId == null
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _showEditor(),
              icon: const Icon(Icons.add),
              label: const Text('Add product'),
            ),
      body: _bootstrapping
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_error!, textAlign: TextAlign.center),
                        const SizedBox(height: 12),
                        ElevatedButton(onPressed: _bootstrap, child: const Text('Retry')),
                      ],
                    ),
                  ),
                )
              : _businesses.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('No business found. Create one first.'),
                          const SizedBox(height: 12),
                          ElevatedButton(
                            onPressed: () => context.push('/business-owner/create'),
                            child: const Text('Create business'),
                          ),
                        ],
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _reloadProducts,
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                        children: [
                          DropdownButtonFormField<String>(
                            value: _businessId,
                            decoration: const InputDecoration(labelText: 'Business'),
                            items: _businesses
                                .map(
                                  (b) => DropdownMenuItem(
                                    value: b.id,
                                    child: Text(b.name),
                                  ),
                                )
                                .toList(),
                            onChanged: _onBusinessChanged,
                          ),
                          const SizedBox(height: 16),
                          if (_loading)
                            const LinearProgressIndicator(minHeight: 2),
                          if (_products.isEmpty)
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 48),
                              child: Center(child: Text('No products yet — tap Add product')),
                            )
                          else
                            ..._products.map((product) {
                              return Card(
                                margin: const EdgeInsets.only(bottom: 10),
                                child: ListTile(
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 8,
                                  ),
                                  leading: ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: SizedBox(
                                      width: 56,
                                      height: 56,
                                      child: WamuNetworkImage(imageUrl: product.imageUrl),
                                    ),
                                  ),
                                  title: Text(product.name),
                                  subtitle: Text(
                                    '${formatUgx(product.price)} · '
                                    'stock ${product.stockQuantity ?? '—'} · '
                                    '${product.status}',
                                  ),
                                  isThreeLine: true,
                                  trailing: PopupMenuButton<String>(
                                    onSelected: (value) async {
                                      switch (value) {
                                        case 'edit':
                                          await _showEditor(existing: product);
                                        case 'photo':
                                          await _pickAndUploadImage(product);
                                        case 'oos':
                                          await ref
                                              .read(ownerProductsRepositoryProvider)
                                              .updateProduct(
                                                productId: product.id,
                                                status: 'OUT_OF_STOCK',
                                                stockQuantity: 0,
                                              );
                                          await _reloadProducts();
                                      }
                                    },
                                    itemBuilder: (_) => const [
                                      PopupMenuItem(value: 'edit', child: Text('Edit')),
                                      PopupMenuItem(value: 'photo', child: Text('Add photo')),
                                      PopupMenuItem(
                                        value: 'oos',
                                        child: Text('Mark out of stock'),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            }),
                        ],
                      ),
                    ),
    );
  }
}

class ManageOrdersScreen extends ConsumerStatefulWidget {
  const ManageOrdersScreen({super.key});

  @override
  ConsumerState<ManageOrdersScreen> createState() => _ManageOrdersScreenState();
}

class _ManageOrdersScreenState extends ConsumerState<ManageOrdersScreen>
    with WidgetsBindingObserver {
  late Future<
      ({
        List<OrderModel> orders,
        Map<String, Map<String, dynamic>?> deliveries,
        Map<String, String> openDisputes,
      })> _future;
  String? _businessId;
  bool _busy = false;
  bool _live = false;
  Timer? _poll;
  bool _seeded = false;
  final Set<String> _knownOrderIds = {};
  final Set<String> _knownPaidIds = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _future = _load().then((data) {
      _onOrdersSnapshot(data.orders);
      _schedulePoll(data.orders);
      return data;
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _reload();
  }

  Future<
      ({
        List<OrderModel> orders,
        Map<String, Map<String, dynamic>?> deliveries,
        Map<String, String> openDisputes,
      })> _load() async {
    final response = await ref.read(apiClientProvider).get('/businesses/mine');
    final list = (response.data as List).cast<Map<String, dynamic>>();
    if (list.isEmpty) {
      return (
        orders: <OrderModel>[],
        deliveries: <String, Map<String, dynamic>?>{},
        openDisputes: <String, String>{},
      );
    }
    _businessId = list.first['id']?.toString();
    final orders = await ref.read(ordersRepositoryProvider).getBusinessOrders(_businessId!);
    final deliveries = <String, Map<String, dynamic>?>{};
    final riderRepo = ref.read(ridersRepositoryProvider);
    for (final order in orders) {
      final s = order.status.toUpperCase();
      if (s == 'CANCELLED' || s == 'PENDING') continue;
      deliveries[order.id] = await riderRepo.deliveryForOrder(order.id);
    }
    final openDisputes = <String, String>{};
    try {
      final rows = await ref.read(ordersRepositoryProvider).listBusinessDisputes();
      for (final d in rows) {
        if ((d['status']?.toString() ?? '').toUpperCase() != 'OPEN') continue;
        final oid = d['order_id']?.toString();
        final reason = d['reason']?.toString() ?? 'OPEN';
        if (oid != null && oid.isNotEmpty) openDisputes[oid] = reason;
      }
    } catch (_) {
      // Non-fatal — orders still render
    }
    return (orders: orders, deliveries: deliveries, openDisputes: openDisputes);
  }

  void _reload() {
    setState(() => _future = _load().then((data) {
          _onOrdersSnapshot(data.orders);
          _schedulePoll(data.orders);
          return data;
        }));
  }

  void _onOrdersSnapshot(List<OrderModel> orders) {
    final ids = orders.map((o) => o.id).toSet();
    final paid = orders
        .where((o) => o.paymentStatus?.toUpperCase() == 'SUCCESS')
        .map((o) => o.id)
        .toSet();
    if (!_seeded) {
      _knownOrderIds
        ..clear()
        ..addAll(ids);
      _knownPaidIds
        ..clear()
        ..addAll(paid);
      _seeded = true;
      return;
    }
    final newOrders = ids.difference(_knownOrderIds);
    final newlyPaid = paid.difference(_knownPaidIds);
    _knownOrderIds
      ..clear()
      ..addAll(ids);
    _knownPaidIds
      ..clear()
      ..addAll(paid);
    if (!mounted) return;
    if (newlyPaid.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            newlyPaid.length == 1
                ? 'Order paid — fulfill now'
                : '${newlyPaid.length} orders paid — fulfill now',
          ),
          backgroundColor: Colors.green.shade700,
        ),
      );
    } else if (newOrders.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            newOrders.length == 1 ? 'New order received' : '${newOrders.length} new orders',
          ),
        ),
      );
    }
  }

  void _schedulePoll(List<OrderModel> orders) {
    _poll?.cancel();
    // Always poll while Manage Orders is open so the first new order is not missed.
    if (mounted) setState(() => _live = true);
    _poll = Timer.periodic(const Duration(seconds: 4), (_) {
      if (!mounted) return;
      _reload();
    });
  }

  Future<void> _advance(OrderModel order) async {
    final status = nextFulfillmentStatus(order.status);
    if (status == null) return;
    if (order.paymentStatus?.toUpperCase() != 'SUCCESS') {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Customer hasn’t paid yet')),
        );
      }
      return;
    }
    setState(() => _busy = true);
    try {
      await ref.read(ordersRepositoryProvider).updateStatus(order.id, status);
      if (mounted) _reload();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reject(OrderModel order) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reject order?'),
        content: const Text('This cancels the order for the customer.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Reject'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref.read(ordersRepositoryProvider).updateStatus(order.id, 'CANCELLED');
      if (mounted) _reload();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool _canReject(OrderModel order) {
    final s = order.status.toUpperCase();
    return !_busy &&
        s != 'CANCELLED' &&
        s != 'DELIVERED' &&
        s != 'REFUNDED';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Manage orders'),
        actions: [
          if (_live)
            const Padding(
              padding: EdgeInsets.only(right: 12),
              child: Center(
                child: Row(
                  children: [
                    Icon(Icons.sensors, size: 16),
                    SizedBox(width: 4),
                    Text('Live', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                  ],
                ),
              ),
            ),
          IconButton(
            tooltip: 'Refresh',
            onPressed: _busy ? null : _reload,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: FutureBuilder<
          ({
            List<OrderModel> orders,
            Map<String, Map<String, dynamic>?> deliveries,
            Map<String, String> openDisputes,
          })>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError && !snapshot.hasData) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('${snapshot.error}'),
                  TextButton(onPressed: _reload, child: const Text('Retry')),
                ],
              ),
            );
          }
          final orders = snapshot.data?.orders ?? [];
          final deliveries = snapshot.data?.deliveries ?? {};
          final openDisputes = snapshot.data?.openDisputes ?? {};
          if (orders.isEmpty) {
            return const Center(child: Text('No orders yet for your business'));
          }
          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: orders.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final order = orders[index];
                final payLabel = order.paymentLabel;
                final next = nextFulfillmentStatus(order.status);
                final paid = order.paymentStatus?.toUpperCase() == 'SUCCESS';
                final canAdvance = next != null && !_busy && paid;
                final canReject = _canReject(order);
                final delivery = deliveries[order.id];
                final rider = delivery?['rider'] as Map?;
                final riderName = rider?['display_name']?.toString();
                final delStatus = delivery?['status']?.toString();
                final delLabel = delStatus == null ? null : deliveryStatusLabel(delStatus);
                final disputeReason = openDisputes[order.id];
                return Card(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        ListTile(
                          title: Text('${formatUgx(order.total)} · ${order.status}'),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                order.items
                                    .map((i) => '${i.quantity}× ${i.name}')
                                    .join(', '),
                              ),
                              if (payLabel.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text(
                                    payLabel,
                                    style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                      color: orderPaymentColor(order.paymentStatus),
                                    ),
                                  ),
                                ),
                              if (disputeReason != null)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text(
                                    'Dispute open · $disputeReason',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w700,
                                      color: Colors.red.shade700,
                                    ),
                                  ),
                                ),
                              if (delLabel != null)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text(
                                    riderName == null
                                        ? 'Delivery: $delLabel'
                                        : 'Delivery: $delLabel · $riderName',
                                    style: TextStyle(
                                      color: Colors.blueGrey.shade700,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          isThreeLine: true,
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                          child: Row(
                            children: [
                              if (canAdvance)
                                FilledButton(
                                  onPressed: () => _advance(order),
                                  child: Text('Mark $next'),
                                )
                              else if (next != null && !paid)
                                Text(
                                  'Waiting for payment',
                                  style: TextStyle(color: Colors.orange.shade800),
                                ),
                              const Spacer(),
                              if (canReject)
                                TextButton(
                                  onPressed: () => _reject(order),
                                  child: Text(
                                    'Reject',
                                    style: TextStyle(color: Colors.red.shade700),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

/// Owner inbox for customer reviews + reply.
class ManageReviewsScreen extends ConsumerStatefulWidget {
  const ManageReviewsScreen({super.key});

  @override
  ConsumerState<ManageReviewsScreen> createState() => _ManageReviewsScreenState();
}

class _ManageReviewsScreenState extends ConsumerState<ManageReviewsScreen> {
  late Future<List<ReviewModel>> _future;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<ReviewModel>> _load() async {
    final response = await ref.read(apiClientProvider).get('/businesses/mine');
    final list = (response.data as List).cast<Map<String, dynamic>>();
    if (list.isEmpty) return [];
    final businessId = list.first['id']?.toString();
    if (businessId == null) return [];
    return ref.read(reviewsRepositoryProvider).getReviews(businessId);
  }

  void _reload() => setState(() => _future = _load());

  Future<void> _reply(ReviewModel review) async {
    final controller = TextEditingController(text: review.reply ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reply to review'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: 'Thank the customer…'),
          maxLines: 4,
          autofocus: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Send')),
        ],
      ),
    );
    final text = controller.text.trim();
    controller.dispose();
    if (ok != true || text.isEmpty || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref.read(reviewsRepositoryProvider).replyToReview(
            reviewId: review.id,
            reply: text,
          );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Reply posted')),
        );
        _reload();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Customer reviews')),
      body: FutureBuilder<List<ReviewModel>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('${snapshot.error}'),
                  TextButton(onPressed: _reload, child: const Text('Retry')),
                ],
              ),
            );
          }
          final reviews = snapshot.data ?? [];
          if (reviews.isEmpty) {
            return const Center(child: Text('No reviews yet'));
          }
          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: reviews.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final review = reviews[index];
                final hasReply = (review.reply ?? '').trim().isNotEmpty;
                return Card(
                  child: ListTile(
                    leading: const Icon(Icons.star, color: Colors.amber),
                    title: Text('${review.rating}/5'),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if ((review.comment ?? '').isNotEmpty) Text(review.comment!),
                        if (hasReply)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              'Your reply: ${review.reply}',
                              style: const TextStyle(fontStyle: FontStyle.italic),
                            ),
                          ),
                      ],
                    ),
                    isThreeLine: hasReply || (review.comment ?? '').isNotEmpty,
                    trailing: TextButton(
                      onPressed: _busy ? null : () => _reply(review),
                      child: Text(hasReply ? 'Edit' : 'Reply'),
                    ),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}
