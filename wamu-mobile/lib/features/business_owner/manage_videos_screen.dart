import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/media_url.dart';
import '../../core/network/api_client.dart';
import '../../core/network/api_error.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/models/discover_video_model.dart';
import '../../shared/models/product_model.dart';
import '../../shared/widgets/wamu_network_image.dart';
import '../discover/discover_repository.dart';
import 'owner_products_repository.dart';

/// Merchant publishes + manages short shop videos on Discover.
class ManageVideosScreen extends ConsumerStatefulWidget {
  const ManageVideosScreen({super.key});

  @override
  ConsumerState<ManageVideosScreen> createState() => _ManageVideosScreenState();
}

class _ManageVideosScreenState extends ConsumerState<ManageVideosScreen>
    with SingleTickerProviderStateMixin {
  final _captionCtrl = TextEditingController();
  final _urlCtrl = TextEditingController();
  late final TabController _tabs;
  String? _businessId;
  String? _uploadedPosterUrl;
  String? _uploadedOriginalUrl;
  int? _uploadedBytes;
  String? _selectedProductId;
  List<ProductModel> _products = [];
  bool _loading = true;
  bool _busy = false;
  String? _error;
  List<DiscoverVideoModel> _mine = [];
  bool _mineLoading = false;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _tabs.addListener(() {
      if (_tabs.index == 1 && !_tabs.indexIsChanging) {
        _loadMine();
      }
    });
    _loadBiz();
  }

  @override
  void dispose() {
    _tabs.dispose();
    _captionCtrl.dispose();
    _urlCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadBiz() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final response = await ref.read(apiClientProvider).get('/businesses/mine');
      final list = (response.data as List).cast<Map<String, dynamic>>();
      if (list.isNotEmpty) {
        _businessId = list.first['id']?.toString();
        if (_businessId != null) {
          _products = await ref
              .read(ownerProductsRepositoryProvider)
              .listProducts(_businessId!);
        }
      }
    } catch (e) {
      _error = apiErrorMessage(e);
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadMine() async {
    final bizId = _businessId;
    if (bizId == null) return;
    setState(() => _mineLoading = true);
    try {
      final list =
          await ref.read(discoverRepositoryProvider).getMyVideos(businessId: bizId);
      if (mounted) setState(() => _mine = list);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(apiErrorMessage(e))),
        );
      }
    } finally {
      if (mounted) setState(() => _mineLoading = false);
    }
  }

  Future<void> _pickAndUpload() async {
    final file = await ImagePicker().pickVideo(source: ImageSource.gallery);
    if (file == null) return;
    setState(() => _busy = true);
    try {
      final bytes = await file.readAsBytes();
      final form = FormData.fromMap({
        'file': MultipartFile.fromBytes(
          bytes,
          filename: file.name.isNotEmpty ? file.name : 'clip.mp4',
        ),
      });
      final response =
          await ref.read(apiClientProvider).dio.post('/media/upload', data: form);
      final map = response.data as Map;
      final url = map['url']?.toString();
      final poster = map['poster_url']?.toString();
      final original = map['original_url']?.toString();
      final size = map['bytes'];
      if (url == null || url.isEmpty) throw Exception('Upload returned no URL');
      if (mounted) {
        setState(() {
          _urlCtrl.text = url;
          _uploadedPosterUrl = (poster != null && poster.isNotEmpty) ? poster : null;
          _uploadedOriginalUrl =
              (original != null && original.isNotEmpty) ? original : null;
          _uploadedBytes = size is int ? size : int.tryParse('$size');
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Video ready — add a caption and publish')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(apiErrorMessage(e))),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _publish() async {
    final bizId = _businessId;
    final url = _urlCtrl.text.trim();
    if (bizId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Create a business first')),
      );
      return;
    }
    if (url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Upload a clip or paste a video URL')),
      );
      return;
    }
    setState(() => _busy = true);
    try {
      await ref.read(discoverRepositoryProvider).createVideo(
            businessId: bizId,
            videoUrl: url,
            caption: _captionCtrl.text.trim().isEmpty ? null : _captionCtrl.text.trim(),
            posterUrl: _uploadedPosterUrl,
            originalVideoUrl: _uploadedOriginalUrl,
            productId: _selectedProductId,
            fileSizeBytes: _uploadedBytes,
          );
      if (!mounted) return;
      _captionCtrl.clear();
      _urlCtrl.clear();
      _uploadedPosterUrl = null;
      _uploadedOriginalUrl = null;
      _uploadedBytes = null;
      _selectedProductId = null;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Published to Local videos')),
      );
      await _loadMine();
      _tabs.animateTo(1);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(apiErrorMessage(e))),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmRemove(DiscoverVideoModel video) async {
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove this video?'),
        content: const Text(
          'Archive hides it from Discover but you can restore later.\n'
          'Delete permanently removes it for good.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'archive'),
            child: const Text('Archive'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'permanent'),
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
            child: const Text('Delete permanently'),
          ),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref.read(discoverRepositoryProvider).deleteVideo(
            video.id,
            permanent: choice == 'permanent',
          );
      if (!mounted) return;
      if (choice == 'permanent') {
        setState(() => _mine = _mine.where((v) => v.id != video.id).toList());
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Video permanently deleted')),
        );
      } else {
        await _loadMine();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Video archived — hidden from Discover')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(apiErrorMessage(e))),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore(DiscoverVideoModel video) async {
    setState(() => _busy = true);
    try {
      final restored =
          await ref.read(discoverRepositoryProvider).restoreVideo(video.id);
      if (!mounted) return;
      setState(() {
        _mine = [
          for (final v in _mine) v.id == restored.id ? restored : v,
        ];
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Video restored to Discover')),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(apiErrorMessage(e))),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Videos'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'Publish'),
            Tab(text: 'My Videos'),
          ],
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_error!, textAlign: TextAlign.center),
                      const SizedBox(height: 12),
                      FilledButton(onPressed: _loadBiz, child: const Text('Retry')),
                    ],
                  ),
                )
              : TabBarView(
                  controller: _tabs,
                  children: [
                    _buildPublishTab(),
                    _buildMineTab(),
                  ],
                ),
    );
  }

  Widget _buildPublishTab() {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          'Publish a short clip so customers can Chat to Order from Discover.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _captionCtrl,
          decoration: const InputDecoration(
            labelText: 'Caption',
            hintText: 'Fresh chapati today…',
          ),
          maxLength: 500,
          maxLines: 2,
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<String?>(
          // ignore: deprecated_member_use
          value: _selectedProductId,
          decoration: const InputDecoration(
            labelText: 'Linked product (optional)',
            helperText: 'Customers see this product on the clip',
          ),
          items: [
            const DropdownMenuItem<String?>(
              value: null,
              child: Text('No specific product'),
            ),
            ..._products.map(
              (p) => DropdownMenuItem<String?>(
                value: p.id,
                child: Text(p.name, overflow: TextOverflow.ellipsis),
              ),
            ),
          ],
          onChanged: _busy
              ? null
              : (v) => setState(() => _selectedProductId = v),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _urlCtrl,
          decoration: const InputDecoration(
            labelText: 'Video URL',
            hintText: 'Upload below or paste https://…mp4',
          ),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _busy ? null : _pickAndUpload,
          icon: const Icon(Icons.video_library_outlined),
          label: const Text('Upload from gallery'),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _busy ? null : _publish,
          style: FilledButton.styleFrom(
            backgroundColor: AppTheme.accentGreen,
            foregroundColor: Colors.black,
            minimumSize: const Size(double.infinity, 48),
          ),
          child: Text(
            _busy ? 'Working…' : 'Publish',
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
        ),
      ],
    );
  }

  Widget _buildMineTab() {
    if (_mineLoading && _mine.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_mine.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('No videos yet', style: TextStyle(color: Colors.black54)),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => _tabs.animateTo(0),
              child: const Text('Publish your first clip'),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _loadMine,
      child: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: _mine.length,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (context, i) {
          final v = _mine[i];
          final poster = v.displayImage;
          final archived = v.status == 'archived';
          return ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            leading: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 56,
                height: 72,
                child: poster != null
                    ? WamuNetworkImage(
                        imageUrl: resolveMediaUrl(poster) ?? poster,
                        fit: BoxFit.cover,
                      )
                    : const ColoredBox(
                        color: Color(0xFF222222),
                        child: Icon(Icons.videocam, color: Colors.white54),
                      ),
              ),
            ),
            title: Text(
              v.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              archived
                  ? 'Archived · ${v.viewCount} views'
                  : '${v.viewCount} views · ${v.likeCount} likes'
                      '${v.productName != null ? ' · ${v.productName}' : ''}',
            ),
            trailing: archived
                ? TextButton(
                    onPressed: _busy ? null : () => _restore(v),
                    child: const Text('Restore'),
                  )
                : IconButton(
                    tooltip: 'Remove',
                    icon: Icon(Icons.delete_outline, color: Colors.red.shade700),
                    onPressed: _busy ? null : () => _confirmRemove(v),
                  ),
          );
        },
      ),
    );
  }
}
