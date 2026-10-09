import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/media_url.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/widgets/wamu_network_image.dart';
import '../auth/auth_provider.dart';
import '../chat/chat_repository.dart';

/// Edit display name, bio, and avatar (You → Account / profile).
class EditProfileScreen extends ConsumerStatefulWidget {
  const EditProfileScreen({super.key});

  @override
  ConsumerState<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends ConsumerState<EditProfileScreen> {
  final _firstCtrl = TextEditingController();
  final _lastCtrl = TextEditingController();
  final _bioCtrl = TextEditingController();
  bool _saving = false;
  bool _uploading = false;
  String? _avatarUrl;

  @override
  void initState() {
    super.initState();
    final u = ref.read(authProvider).user;
    _firstCtrl.text = u?.firstName ?? '';
    _lastCtrl.text = u?.lastName ?? '';
    _bioCtrl.text = u?.bio ?? '';
    _avatarUrl = u?.avatarUrl;
  }

  @override
  void dispose() {
    _firstCtrl.dispose();
    _lastCtrl.dispose();
    _bioCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickAvatar() async {
    final picker = ImagePicker();
    final file = await picker.pickImage(source: ImageSource.gallery, imageQuality: 85, maxWidth: 1024);
    if (file == null) return;
    setState(() => _uploading = true);
    try {
      final bytes = await file.readAsBytes();
      final url = await ref.read(chatRepositoryProvider).uploadBytes(
            bytes,
            filename: 'avatar-${DateTime.now().millisecondsSinceEpoch}.jpg',
            contentType: 'image/jpeg',
          );
      if (mounted) setState(() => _avatarUrl = url);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _save() async {
    final first = _firstCtrl.text.trim();
    if (first.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('First name is required')),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      await ref.read(authProvider.notifier).updateFullProfile(
            firstName: first,
            lastName: _lastCtrl.text.trim(),
            bio: _bioCtrl.text.trim(),
            avatarUrl: _avatarUrl,
          );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Profile updated')),
        );
        context.pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final letter = _firstCtrl.text.trim().isNotEmpty
        ? _firstCtrl.text.trim()[0].toUpperCase()
        : 'W';
    final hasAvatar = resolveMediaUrl(_avatarUrl)?.isNotEmpty == true;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit profile'),
        actions: [
          TextButton(
            onPressed: _saving || _uploading ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Save'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Center(
            child: Stack(
              children: [
                CircleAvatar(
                  radius: 52,
                  backgroundColor: AppTheme.accentGreen,
                  child: hasAvatar
                      ? ClipOval(
                          child: WamuNetworkImage(
                            imageUrl: _avatarUrl,
                            width: 104,
                            height: 104,
                          ),
                        )
                      : Text(
                          letter,
                          style: const TextStyle(
                            fontSize: 36,
                            fontWeight: FontWeight.w800,
                            color: Colors.black,
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
                      onTap: _uploading ? null : _pickAvatar,
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: _uploading
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                              )
                            : const Icon(Icons.camera_alt, size: 18, color: Colors.black),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          const Center(
            child: Text('Tap camera to change photo', style: TextStyle(color: Colors.grey)),
          ),
          const SizedBox(height: 16),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.qr_code_2),
            title: const Text('My QR code'),
            subtitle: const Text('Sign another device into this account'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/account-qr'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _firstCtrl,
            decoration: const InputDecoration(labelText: 'First name'),
            textCapitalization: TextCapitalization.words,
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _lastCtrl,
            decoration: const InputDecoration(labelText: 'Last name'),
            textCapitalization: TextCapitalization.words,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _bioCtrl,
            decoration: const InputDecoration(
              labelText: 'About',
              hintText: 'Hey there! I am using Wamu',
            ),
            maxLines: 3,
            maxLength: 140,
          ),
        ],
      ),
    );
  }
}
