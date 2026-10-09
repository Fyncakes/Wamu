import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/theme/app_theme.dart';
import '../../shared/widgets/loading_view.dart';
import '../chat/chat_repository.dart';
import '../home/nearby_location.dart';
import 'riders_repository.dart';

/// Multi-step Become a Wamu Rider → KYC → AI signals → wait for admin.
class RiderOnboardingScreen extends ConsumerStatefulWidget {
  const RiderOnboardingScreen({super.key});

  @override
  ConsumerState<RiderOnboardingScreen> createState() => _RiderOnboardingScreenState();
}

class _RiderOnboardingScreenState extends ConsumerState<RiderOnboardingScreen> {
  int _step = 0;
  bool _busy = false;
  Map<String, dynamic>? _verification;
  String? _error;
  Timer? _statusPoll;

  final _name = TextEditingController();
  final _dob = TextEditingController();
  final _nin = TextEditingController();
  final _emergencyName = TextEditingController();
  final _emergencyPhone = TextEditingController();
  final _location = TextEditingController(text: 'Kampala');
  final _licenceNo = TextEditingController();
  final _licenceExpiry = TextEditingController();
  final _licenceClass = TextEditingController(text: 'A');
  final _motoReg = TextEditingController();
  final _motoOwner = TextEditingController(text: 'Owner');
  final _insPolicy = TextEditingController();
  final _insReg = TextEditingController();
  final _insFrom = TextEditingController();
  final _insTo = TextEditingController();

  final Map<String, String> _docUrls = {};

  static const _steps = [
    'Personal',
    'National ID',
    'Licence',
    'Motorcycle',
    'Insurance',
    'Selfie',
    'Submit',
  ];

  @override
  void initState() {
    super.initState();
    _bootstrap();
    _statusPoll = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted) return;
      final status = '${_verification?['status'] ?? ''}'.toUpperCase();
      if (status == 'SUBMITTED' ||
          status == 'UNDER_REVIEW' ||
          status == 'PENDING' ||
          status == 'REUPLOAD_REQUIRED') {
        _bootstrap(silent: true);
      }
    });
  }

  @override
  void dispose() {
    _statusPoll?.cancel();
    for (final c in [
      _name,
      _dob,
      _nin,
      _emergencyName,
      _emergencyPhone,
      _location,
      _licenceNo,
      _licenceExpiry,
      _licenceClass,
      _motoReg,
      _motoOwner,
      _insPolicy,
      _insReg,
      _insFrom,
      _insTo,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _bootstrap({bool silent = false}) async {
    try {
      final v = await ref.read(ridersRepositoryProvider).myVerification();
      if (!mounted) return;
      setState(() {
        _verification = v;
        if (!silent) {
          _hydrate(v);
          final status = '${v['status'] ?? ''}'.toUpperCase();
          if (status == 'UNDER_REVIEW' ||
              status == 'SUBMITTED' ||
              status == 'APPROVED' ||
              status == 'SUSPENDED') {
            _step = _steps.length; // status pane
          } else if (status == 'NEEDS_REUPLOAD' || status == 'REJECTED') {
            _step = 0;
          }
        } else {
          // Live approval: jump to status pane when admin decides.
          final status = '${v['status'] ?? ''}'.toUpperCase();
          if (status == 'APPROVED' ||
              status == 'SUSPENDED' ||
              status == 'REJECTED' ||
              status == 'UNDER_REVIEW' ||
              status == 'SUBMITTED') {
            _step = _steps.length;
          }
        }
      });
    } catch (_) {
      // not enrolled yet
    }
  }

  void _hydrate(Map<String, dynamic> v) {
    _name.text = '${v['display_name'] ?? _name.text}';
    _dob.text = '${v['date_of_birth'] ?? ''}';
    _emergencyName.text = '${v['emergency_contact_name'] ?? ''}';
    _emergencyPhone.text = '${v['emergency_contact_phone'] ?? ''}';
    _location.text = '${v['location_text'] ?? _location.text}';
    _licenceNo.text = '${v['licence_number'] ?? ''}'.replaceAll('*', '');
    _licenceExpiry.text = '${v['licence_expiry'] ?? ''}';
    _licenceClass.text = '${v['licence_class'] ?? _licenceClass.text}';
    _motoReg.text = '${v['motorcycle_reg'] ?? v['plate_number'] ?? ''}';
    _motoOwner.text = '${v['motorcycle_ownership'] ?? _motoOwner.text}';
    _insPolicy.text = '${v['insurance_policy'] ?? ''}'.replaceAll('*', '');
    _insReg.text = '${v['insurance_reg'] ?? ''}';
    _insFrom.text = '${v['insurance_valid_from'] ?? ''}';
    _insTo.text = '${v['insurance_valid_to'] ?? ''}';
    final docs = v['documents'];
    if (docs is List) {
      for (final d in docs) {
        if (d is Map && d['doc_type'] != null && d['url'] != null) {
          _docUrls['${d['doc_type']}'] = '${d['url']}';
        }
      }
    }
  }

  Future<void> _pickDoc(String docType) async {
    final picker = ImagePicker();
    final file = await picker.pickImage(
      source: kIsWeb ? ImageSource.gallery : ImageSource.camera,
      imageQuality: 85,
      maxWidth: 1600,
    );
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
      final v = await ref.read(ridersRepositoryProvider).uploadDocument(
            docType: docType,
            url: url,
            mimeType: 'image/jpeg',
          );
      if (!mounted) return;
      setState(() {
        _docUrls[docType] = url;
        _verification = v;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _savePersonal() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final origin = await resolveNearbyOrigin(preferGps: true);
      final v = await ref.read(ridersRepositoryProvider).registerRider(
            fullName: _name.text.trim(),
            dateOfBirth: _dob.text.trim().isEmpty ? null : _dob.text.trim(),
            nin: _nin.text.trim().isEmpty ? null : _nin.text.trim(),
            emergencyContactName:
                _emergencyName.text.trim().isEmpty ? null : _emergencyName.text.trim(),
            emergencyContactPhone:
                _emergencyPhone.text.trim().isEmpty ? null : _emergencyPhone.text.trim(),
            locationText: _location.text.trim().isEmpty ? null : _location.text.trim(),
            plateNumber: _motoReg.text.trim().isEmpty ? null : _motoReg.text.trim(),
            lat: origin.lat,
            lng: origin.lng,
          );
      _verification = v;
      return true;
    } catch (e) {
      setState(() => _error = '$e');
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _saveVehicleDocs() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final v = await ref.read(ridersRepositoryProvider).updateVehicleDocs({
        if (_licenceNo.text.trim().isNotEmpty) 'licence_number': _licenceNo.text.trim(),
        if (_licenceExpiry.text.trim().isNotEmpty) 'licence_expiry': _licenceExpiry.text.trim(),
        if (_licenceClass.text.trim().isNotEmpty) 'licence_class': _licenceClass.text.trim(),
        if (_motoReg.text.trim().isNotEmpty) 'motorcycle_reg': _motoReg.text.trim(),
        if (_motoOwner.text.trim().isNotEmpty) 'motorcycle_ownership': _motoOwner.text.trim(),
        if (_motoReg.text.trim().isNotEmpty) 'plate_number': _motoReg.text.trim(),
        if (_insPolicy.text.trim().isNotEmpty) 'insurance_policy': _insPolicy.text.trim(),
        if (_insReg.text.trim().isNotEmpty) 'insurance_reg': _insReg.text.trim(),
        if (_insFrom.text.trim().isNotEmpty) 'insurance_valid_from': _insFrom.text.trim(),
        if (_insTo.text.trim().isNotEmpty) 'insurance_valid_to': _insTo.text.trim(),
      });
      _verification = v;
      return true;
    } catch (e) {
      setState(() => _error = '$e');
      return false;
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
      await _savePersonal();
      await _saveVehicleDocs();
      final v = await ref.read(ridersRepositoryProvider).submitVerification();
      if (!mounted) return;
      setState(() {
        _verification = v;
        _step = _steps.length;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _next() async {
    if (_step == 0) {
      if (_name.text.trim().length < 2 || _nin.text.trim().length < 8) {
        setState(() => _error = 'Full name and NIN are required');
        return;
      }
      if (!await _savePersonal()) return;
    }
    if (_step == 1) {
      if (!_docUrls.containsKey('NATIONAL_ID_FRONT') || !_docUrls.containsKey('NATIONAL_ID_BACK')) {
        setState(() => _error = 'Upload National ID front and back');
        return;
      }
    }
    if (_step == 2) {
      if (_licenceNo.text.trim().isEmpty || !_docUrls.containsKey('LICENCE_FRONT')) {
        setState(() => _error = 'Licence number and front photo required');
        return;
      }
      if (!await _saveVehicleDocs()) return;
    }
    if (_step == 3) {
      if (_motoReg.text.trim().isEmpty || !_docUrls.containsKey('MOTORCYCLE')) {
        setState(() => _error = 'Motorcycle registration and document required');
        return;
      }
      if (!await _saveVehicleDocs()) return;
    }
    if (_step == 4) {
      if (_insPolicy.text.trim().isEmpty || !_docUrls.containsKey('INSURANCE')) {
        setState(() => _error = 'Insurance policy and document required');
        return;
      }
      if (!await _saveVehicleDocs()) return;
    }
    if (_step == 5) {
      if (!_docUrls.containsKey('SELFIE')) {
        setState(() => _error = 'Selfie required for identity comparison');
        return;
      }
    }
    if (_step == 6) {
      await _submit();
      return;
    }
    setState(() {
      _error = null;
      _step += 1;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_step >= _steps.length) {
      return _StatusPane(
        verification: _verification,
        onDashboard: () => context.go('/rider'),
        onRefresh: _bootstrap,
        onFix: () => setState(() => _step = 0),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Become a Wamu Rider'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(28),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: LinearProgressIndicator(
                    value: (_step + 1) / _steps.length,
                    color: AppTheme.accentGreen,
                    backgroundColor: AppTheme.accentGreen.withValues(alpha: 0.2),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  '${_step + 1}/${_steps.length}',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ],
            ),
          ),
        ),
      ),
      body: _busy && _verification == null
          ? const LoadingView()
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  _steps[_step],
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 4),
                Text(
                  _stepHint(_step),
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 16),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(_error!, style: const TextStyle(color: Colors.red)),
                  ),
                ..._stepFields(),
                const SizedBox(height: 24),
                Row(
                  children: [
                    if (_step > 0)
                      OutlinedButton(
                        onPressed: _busy ? null : () => setState(() => _step -= 1),
                        child: const Text('Back'),
                      ),
                    const Spacer(),
                    FilledButton(
                      onPressed: _busy ? null : _next,
                      style: FilledButton.styleFrom(
                        backgroundColor: AppTheme.accentGreen,
                        foregroundColor: Colors.black,
                      ),
                      child: Text(_step == 6 ? 'Submit for verification' : 'Continue'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  'AI checks are Wamu signals for admin review — not government proof. '
                  'Authorized NIRA/URA-style verification can plug in later.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.black54),
                ),
              ],
            ),
    );
  }

  String _stepHint(int s) => switch (s) {
        0 => 'Tell us who you are. Wamu will issue your Rider ID.',
        1 => 'Upload clear photos of your National ID (front and back).',
        2 => 'Driving licence details and photo — motorcycle class required.',
        3 => 'Motorcycle registration and ownership / authorisation papers.',
        4 => 'Valid insurance that matches your motorcycle registration.',
        5 => 'A clear live selfie for identity comparison.',
        _ => 'Review and submit. An admin will make the final decision.',
      };

  List<Widget> _stepFields() {
    switch (_step) {
      case 0:
        return [
          _field(_name, 'Full name'),
          _field(_dob, 'Date of birth (YYYY-MM-DD or year e.g. 1994)'),
          _field(_nin, 'NIN / National ID number'),
          _field(_emergencyName, 'Emergency contact name'),
          _field(_emergencyPhone, 'Emergency contact phone'),
          _field(_location, 'Location'),
          if (_verification?['wamu_rider_ref'] != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SelectableText(
                'Rider ID: ${_verification!['wamu_rider_ref']}',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
        ];
      case 1:
        return [
          _docTile('NATIONAL_ID_FRONT', 'National ID — front'),
          _docTile('NATIONAL_ID_BACK', 'National ID — back'),
        ];
      case 2:
        return [
          _field(_licenceNo, 'Licence number'),
          _field(_licenceExpiry, 'Expiry (YYYY-MM-DD)'),
          _field(_licenceClass, 'Class / entitlement (e.g. A)'),
          _docTile('LICENCE_FRONT', 'Licence photo'),
          _docTile('LICENCE_BACK', 'Licence back (optional)'),
        ];
      case 3:
        return [
          _field(_motoReg, 'Registration number'),
          _field(_motoOwner, 'Ownership / authorisation'),
          _docTile('MOTORCYCLE', 'Motorcycle documents'),
        ];
      case 4:
        return [
          _field(_insPolicy, 'Policy number'),
          _field(_insReg, 'Motorcycle registration on policy'),
          _field(_insFrom, 'Valid from (YYYY-MM-DD)'),
          _field(_insTo, 'Valid to (YYYY-MM-DD)'),
          _docTile('INSURANCE', 'Insurance document'),
        ];
      case 5:
        return [_docTile('SELFIE', 'Live / clear selfie')];
      default:
        return [
          _ReviewCard(verification: _verification, docUrls: _docUrls),
        ];
    }
  }

  Widget _field(TextEditingController c, String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: c,
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
      ),
    );
  }

  Widget _docTile(String type, String label) {
    final has = _docUrls.containsKey(type);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        leading: Icon(
          has ? Icons.check_circle : Icons.upload_file_outlined,
          color: has ? AppTheme.accentGreen : null,
        ),
        title: Text(label),
        subtitle: Text(has ? 'Uploaded' : 'Tap to capture / upload'),
        trailing: _busy
            ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.chevron_right),
        onTap: _busy ? null : () => _pickDoc(type),
      ),
    );
  }
}

class _ReviewCard extends StatelessWidget {
  const _ReviewCard({required this.verification, required this.docUrls});

  final Map<String, dynamic>? verification;
  final Map<String, String> docUrls;

  @override
  Widget build(BuildContext context) {
    final ref = verification?['wamu_rider_ref'] ?? '—';
    final name = verification?['display_name'] ?? '—';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Rider ID: $ref', style: const TextStyle(fontWeight: FontWeight.w800)),
        Text('Name: $name'),
        const SizedBox(height: 8),
        Text('${docUrls.length} documents attached'),
        const SizedBox(height: 8),
        const Text(
          'After submit, Wamu AI will score each document group. '
          'An admin must still approve before you can go online.',
        ),
      ],
    );
  }
}

class _StatusPane extends StatelessWidget {
  const _StatusPane({
    required this.verification,
    required this.onDashboard,
    required this.onRefresh,
    required this.onFix,
  });

  final Map<String, dynamic>? verification;
  final VoidCallback onDashboard;
  final VoidCallback onRefresh;
  final VoidCallback onFix;

  @override
  Widget build(BuildContext context) {
    final status = '${verification?['status'] ?? 'SUBMITTED'}'.toUpperCase();
    final ai = '${verification?['ai_result'] ?? '—'}';
    final checks = (verification?['ai_checks'] is Map)
        ? Map<String, dynamic>.from(verification!['ai_checks'] as Map)
        : <String, dynamic>{};
    final checkMap = checks['checks'] is Map
        ? Map<String, dynamic>.from(checks['checks'] as Map)
        : <String, dynamic>{};

    final approved = status == 'APPROVED';
    final needsFix = status == 'NEEDS_REUPLOAD' || status == 'REJECTED';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Verification status'),
        actions: [IconButton(onPressed: onRefresh, icon: const Icon(Icons.refresh))],
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Icon(
            approved ? Icons.celebration_outlined : Icons.hourglass_top_outlined,
            size: 64,
            color: AppTheme.accentGreen,
          ),
          const SizedBox(height: 16),
          Text(
            approved ? 'Congratulations!' : 'Application received',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Text(
            approved
                ? 'You are now a Wamu Verified Rider'
                : 'Status: $status · AI result: $ai',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          if (verification?['wamu_rider_ref'] != null) ...[
            const SizedBox(height: 8),
            SelectableText(
              '${verification!['wamu_rider_ref']}',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ],
          ..._expiryAlerts(context, verification),
          if (verification?['rejection_reason'] != null) ...[
            const SizedBox(height: 12),
            Text('${verification!['rejection_reason']}', style: const TextStyle(color: Colors.red)),
          ],
          if (verification?['reupload_fields'] is List) ...[
            const SizedBox(height: 8),
            Text('Please re-upload: ${(verification!['reupload_fields'] as List).join(', ')}'),
          ],
          const SizedBox(height: 20),
          Text('AI signals', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          ...checkMap.entries.map(
            (e) => ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(e.key.replaceAll('_', ' ')),
              trailing: Text(
                '${e.value}',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: e.value == 'PASS'
                      ? Colors.green.shade700
                      : e.value == 'FAIL'
                          ? Colors.red
                          : Colors.orange.shade800,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '${(checks['disclaimer'] ?? verification?['government_verification']?['note']) ?? ''}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.black54),
          ),
          const SizedBox(height: 24),
          if (approved)
            FilledButton(
              onPressed: onDashboard,
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.accentGreen,
                foregroundColor: Colors.black,
              ),
              child: const Text('Go to Rider Dashboard'),
            )
          else if (needsFix)
            FilledButton(onPressed: onFix, child: const Text('Fix & re-upload'))
          else
            OutlinedButton(onPressed: onRefresh, child: const Text('Refresh status')),
        ],
      ),
    );
  }

  List<Widget> _expiryAlerts(BuildContext context, Map<String, dynamic>? v) {
    if (v == null) return const [];
    final alerts = <Widget>[];
    void check(String label, String? iso) {
      if (iso == null || iso.isEmpty) return;
      final d = DateTime.tryParse(iso);
      if (d == null) return;
      final days = d.difference(DateTime.now()).inDays;
      if (days > 45) return;
      final msg = days < 0
          ? '$label expired ${-days} days ago — re-upload required'
          : '$label expires in $days days';
      alerts.add(
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                days < 0 ? Icons.error_outline : Icons.warning_amber_outlined,
                color: days < 0 ? Colors.redAccent : Colors.orangeAccent,
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  msg,
                  style: TextStyle(
                    color: days < 0 ? Colors.redAccent : Colors.orangeAccent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    check('Driving licence', v['licence_expiry']?.toString());
    check('Insurance', v['insurance_valid_to']?.toString());
    return alerts;
  }
}
