import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/network/api_client.dart';
import '../chat/chat_repository.dart';

/// Shop-owner KYC — collect NIN + ID now; enforcement stays off until admin enables policy.
class MerchantKycScreen extends ConsumerStatefulWidget {
  const MerchantKycScreen({super.key, required this.businessId, this.businessName});

  final String businessId;
  final String? businessName;

  @override
  ConsumerState<MerchantKycScreen> createState() => _MerchantKycScreenState();
}

class _MerchantKycScreenState extends ConsumerState<MerchantKycScreen> {
  int _step = 0;
  bool _busy = false;
  Map<String, dynamic>? _verification;
  String? _error;
  Timer? _poll;

  final _name = TextEditingController();
  final _nin = TextEditingController();
  final _dob = TextEditingController();
  final _tin = TextEditingController();
  final Map<String, String> _docUrls = {};

  static const _steps = ['Identity', 'ID photos', 'Shop + selfie', 'Submit'];
  static const _requiredDocs = [
    'OWNER_ID_FRONT',
    'OWNER_ID_BACK',
    'SELFIE',
    'BUSINESS_PREMISES',
  ];

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(const Duration(seconds: 6), (_) {
      if (!mounted) return;
      final s = '${_verification?['kyc_status'] ?? ''}'.toUpperCase();
      if (s == 'UNDER_REVIEW' || s == 'SUBMITTED' || s == 'NEEDS_REUPLOAD') {
        _load(silent: true);
      }
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _name.dispose();
    _nin.dispose();
    _dob.dispose();
    _tin.dispose();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    try {
      final res = await ref.read(apiClientProvider).get(
            '/businesses/${widget.businessId}/kyc',
          );
      final data = Map<String, dynamic>.from(res.data as Map);
      if (!mounted) return;
      setState(() {
        _verification = data;
        _error = null;
        if (_name.text.isEmpty) {
          _name.text = '${data['owner_full_name'] ?? ''}';
        }
        if (_dob.text.isEmpty) {
          _dob.text = '${data['owner_date_of_birth'] ?? ''}';
        }
        for (final d in (data['documents'] as List? ?? const [])) {
          final m = Map<String, dynamic>.from(d as Map);
          final t = '${m['doc_type'] ?? ''}';
          final u = '${m['url'] ?? ''}';
          if (t.isNotEmpty && u.isNotEmpty) _docUrls[t] = u;
        }
      });
    } catch (e) {
      if (!silent && mounted) {
        setState(() => _error = 'Could not load KYC status');
      }
    }
  }

  Future<void> _saveIdentity() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await ref.read(apiClientProvider).post(
        '/businesses/${widget.businessId}/kyc/register',
        data: {
          'owner_full_name': _name.text.trim(),
          'owner_nin': _nin.text.trim().isEmpty ? null : _nin.text.trim(),
          'owner_date_of_birth': _dob.text.trim().isEmpty ? null : _dob.text.trim(),
          'tin': _tin.text.trim().isEmpty ? null : _tin.text.trim(),
        },
      );
      if (!mounted) return;
      setState(() {
        _verification = Map<String, dynamic>.from(res.data as Map);
        _step = 1;
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not save identity');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickDoc(String docType) async {
    final picker = ImagePicker();
    final file = await picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (file == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final bytes = await file.readAsBytes();
      final url = await ref.read(chatRepositoryProvider).uploadBytes(
            bytes,
            filename: '${docType.toLowerCase()}.jpg',
            contentType: 'image/jpeg',
          );
      if (url.isEmpty) throw StateError('no url');
      final res = await ref.read(apiClientProvider).post(
        '/businesses/${widget.businessId}/kyc/documents',
        data: {
          'doc_type': docType,
          'url': url,
          'mime_type': 'image/jpeg',
        },
      );
      if (!mounted) return;
      setState(() {
        _docUrls[docType] = url;
        _verification = Map<String, dynamic>.from(res.data as Map);
      });
    } catch (_) {
      if (mounted) setState(() => _error = 'Upload failed for $docType');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await ref.read(apiClientProvider).post(
            '/businesses/${widget.businessId}/kyc/submit',
          );
      if (!mounted) return;
      setState(() {
        _verification = Map<String, dynamic>.from(res.data as Map);
        _step = 3;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Submitted for review')),
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Submit failed — check required docs and NIN');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = '${_verification?['kyc_status'] ?? 'DRAFT'}'.toUpperCase();
    final approved = status == 'APPROVED';
    final underReview = status == 'UNDER_REVIEW' || status == 'SUBMITTED';

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.businessName == null
            ? 'Shop verification'
            : 'Verify ${widget.businessName}'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'National ID + shop photos for admin review. '
            'Payouts stay open until you turn enforcement on later.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          Text('Status: $status', style: const TextStyle(fontWeight: FontWeight.w600)),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: TextStyle(color: Colors.red.shade700)),
          ],
          const SizedBox(height: 16),
          if (approved)
            const Text('Your shop is verified. Customers see the badge.')
          else if (underReview)
            const Text('Under review — we will notify you when an admin decides.')
          else ...[
            Row(
              children: List.generate(_steps.length, (i) {
                final active = i == _step;
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Column(
                      children: [
                        CircleAvatar(
                          radius: 12,
                          backgroundColor: active
                              ? Theme.of(context).colorScheme.primary
                              : Colors.grey.shade300,
                          child: Text(
                            '${i + 1}',
                            style: TextStyle(
                              fontSize: 11,
                              color: active ? Colors.white : Colors.black54,
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(_steps[i], style: const TextStyle(fontSize: 10)),
                      ],
                    ),
                  ),
                );
              }),
            ),
            const SizedBox(height: 20),
            if (_step == 0) ...[
              TextField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Owner full name'),
              ),
              TextField(
                controller: _nin,
                decoration: const InputDecoration(labelText: 'National ID (NIN)'),
              ),
              TextField(
                controller: _dob,
                decoration: const InputDecoration(
                  labelText: 'Date of birth (YYYY-MM-DD)',
                ),
              ),
              TextField(
                controller: _tin,
                decoration: const InputDecoration(
                  labelText: 'TIN (optional)',
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _busy ? null : _saveIdentity,
                child: const Text('Continue'),
              ),
            ],
            if (_step == 1) ...[
              _DocTile(
                label: 'National ID — front',
                done: _docUrls.containsKey('OWNER_ID_FRONT'),
                onTap: _busy ? null : () => _pickDoc('OWNER_ID_FRONT'),
              ),
              _DocTile(
                label: 'National ID — back',
                done: _docUrls.containsKey('OWNER_ID_BACK'),
                onTap: _busy ? null : () => _pickDoc('OWNER_ID_BACK'),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  TextButton(onPressed: () => setState(() => _step = 0), child: const Text('Back')),
                  const Spacer(),
                  FilledButton(
                    onPressed: _busy ? null : () => setState(() => _step = 2),
                    child: const Text('Continue'),
                  ),
                ],
              ),
            ],
            if (_step == 2) ...[
              _DocTile(
                label: 'Selfie holding ID',
                done: _docUrls.containsKey('SELFIE'),
                onTap: _busy ? null : () => _pickDoc('SELFIE'),
              ),
              _DocTile(
                label: 'Shop / premises photo',
                done: _docUrls.containsKey('BUSINESS_PREMISES'),
                onTap: _busy ? null : () => _pickDoc('BUSINESS_PREMISES'),
              ),
              _DocTile(
                label: 'TIN certificate (optional)',
                done: _docUrls.containsKey('TIN_CERT'),
                onTap: _busy ? null : () => _pickDoc('TIN_CERT'),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  TextButton(onPressed: () => setState(() => _step = 1), child: const Text('Back')),
                  const Spacer(),
                  FilledButton(
                    onPressed: _busy ? null : () => setState(() => _step = 3),
                    child: const Text('Continue'),
                  ),
                ],
              ),
            ],
            if (_step == 3) ...[
              Text(
                'Required: ${_requiredDocs.where((d) => !_docUrls.containsKey(d)).isEmpty ? 'all uploaded' : _requiredDocs.where((d) => !_docUrls.containsKey(d)).join(', ')}',
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  TextButton(onPressed: () => setState(() => _step = 2), child: const Text('Back')),
                  const Spacer(),
                  FilledButton(
                    onPressed: _busy ? null : _submit,
                    child: const Text('Submit for review'),
                  ),
                ],
              ),
            ],
          ],
          if (_busy) ...[
            const SizedBox(height: 24),
            const Center(child: CircularProgressIndicator()),
          ],
        ],
      ),
    );
  }
}

class _DocTile extends StatelessWidget {
  const _DocTile({required this.label, required this.done, this.onTap});

  final String label;
  final bool done;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(done ? Icons.check_circle : Icons.upload_file, color: done ? Colors.green : null),
      title: Text(label),
      subtitle: Text(done ? 'Uploaded' : 'Tap to upload'),
      onTap: onTap,
    );
  }
}
