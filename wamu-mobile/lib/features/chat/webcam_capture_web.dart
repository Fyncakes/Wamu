import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:typed_data';
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/theme/app_theme.dart';

/// Opens a webcam dialog and returns JPEG bytes, or null if cancelled.
Future<Uint8List?> showChatCameraCapture(BuildContext context) {
  return showDialog<Uint8List>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const _WebcamCaptureDialog(),
  );
}

class _WebcamCaptureDialog extends StatefulWidget {
  const _WebcamCaptureDialog();

  @override
  State<_WebcamCaptureDialog> createState() => _WebcamCaptureDialogState();
}

class _WebcamCaptureDialogState extends State<_WebcamCaptureDialog> {
  html.MediaStream? _stream;
  html.VideoElement? _video;
  String? _viewType;
  String? _error;
  bool _ready = false;
  bool _starting = true;
  bool _capturing = false;
  Uint8List? _preview;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    setState(() {
      _starting = true;
      _error = null;
      _ready = false;
    });
    try {
      final devices = html.window.navigator.mediaDevices;
      if (devices == null) {
        setState(() {
          _starting = false;
          _error = 'Camera API not available. Use gallery instead.';
        });
        return;
      }

      html.MediaStream stream;
      try {
        stream = await devices.getUserMedia({
          'video': true,
          'audio': false,
        }).timeout(const Duration(seconds: 20));
      } on TimeoutException {
        setState(() {
          _starting = false;
          _error =
              'Camera permission timed out.\nClick Allow on the browser prompt, or use gallery.';
        });
        return;
      }

      final viewType = 'wamu-cam-${DateTime.now().millisecondsSinceEpoch}';
      final video = html.VideoElement()
        ..autoplay = true
        ..muted = true
        ..controls = false
        ..setAttribute('playsinline', 'true')
        ..setAttribute('muted', 'true')
        ..srcObject = stream
        ..style.width = '100%'
        ..style.height = '100%'
        ..style.objectFit = 'cover'
        ..style.transform = 'scaleX(-1)'
        ..style.borderRadius = '12px'
        ..style.backgroundColor = '#000';

      // Register BEFORE play so the platform view can attach
      ui_web.platformViewRegistry.registerViewFactory(viewType, (int _) => video);

      // Don't hard-fail on metadata — show preview ASAP
      unawaited(video.play().catchError((_) => null));

      if (!mounted) {
        stream.getTracks().forEach((t) => t.stop());
        return;
      }
      setState(() {
        _stream = stream;
        _video = video;
        _viewType = viewType;
        _ready = true;
        _starting = false;
      });

      // Soft wait for dimensions in background (never blocks UI)
      unawaited(_waitForVideoSize(video));
    } catch (e) {
      if (mounted) {
        setState(() {
          _starting = false;
          _error =
              'Could not open camera.\nAllow access in the address bar, or pick from gallery.\n\n$e';
        });
      }
    }
  }

  Future<void> _waitForVideoSize(html.VideoElement video) async {
    for (var i = 0; i < 60; i++) {
      if (video.videoWidth > 0 && video.readyState >= 2) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  Future<void> _pickFromGallery() async {
    try {
      final file = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        imageQuality: 95,
      );
      if (file == null || !mounted) return;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty || !mounted) return;
      Navigator.of(context).pop(Uint8List.fromList(bytes));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Gallery failed: $e')),
        );
      }
    }
  }

  Future<void> _snap() async {
    final video = _video;
    if (video == null || _capturing) return;
    setState(() => _capturing = true);
    try {
      unawaited(video.play().catchError((_) => null));
      for (var i = 0; i < 40 && video.videoWidth == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      var w = video.videoWidth;
      var h = video.videoHeight;
      if (w == 0 || h == 0) {
        // Last resort: use element client size
        w = video.clientWidth == 0 ? 640 : video.clientWidth;
        h = video.clientHeight == 0 ? 480 : video.clientHeight;
      }
      final canvas = html.CanvasElement(width: w, height: h);
      final ctx = canvas.context2D;
      ctx.translate(w, 0);
      ctx.scale(-1, 1);
      ctx.drawImageScaled(video, 0, 0, w, h);

      final dataUrl = canvas.toDataUrl('image/jpeg', 0.92);
      final comma = dataUrl.indexOf(',');
      if (comma < 0) throw StateError('Empty capture');
      final bytes = Uint8List.fromList(base64Decode(dataUrl.substring(comma + 1)));
      if (bytes.isEmpty) throw StateError('Empty capture');
      if (!mounted) return;
      setState(() {
        _preview = bytes;
        _capturing = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _capturing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not capture: $e')),
        );
      }
    }
  }

  void _usePhoto() {
    final bytes = _preview;
    if (bytes == null) return;
    Navigator.of(context).pop(bytes);
  }

  void _retake() => setState(() => _preview = null);

  @override
  void dispose() {
    _stream?.getTracks().forEach((t) => t.stop());
    _video?.srcObject = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    return Dialog(
      backgroundColor: Theme.of(context).brightness == Brightness.dark
          ? AppTheme.messengerElevated
          : Colors.white,
      insetPadding: const EdgeInsets.all(20),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                preview == null ? 'Take a photo' : 'Use this photo?',
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 18),
              ),
              const SizedBox(height: 12),
              AspectRatio(
                aspectRatio: 3 / 4,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: ColoredBox(
                    color: Colors.black,
                    child: _error != null
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Text(
                                _error!,
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: Colors.white70, height: 1.35),
                              ),
                            ),
                          )
                        : preview != null
                            ? Image.memory(preview, fit: BoxFit.cover)
                            : _starting || _viewType == null
                                ? const Center(
                                    child: CircularProgressIndicator(color: AppTheme.accentGreen),
                                  )
                                : HtmlElementView(viewType: _viewType!),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              if (preview == null) ...[
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _capturing ? null : () => Navigator.of(context).pop(),
                        child: const Text('Cancel'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _ready && !_capturing && _error == null ? _snap : null,
                        style: FilledButton.styleFrom(
                          backgroundColor: AppTheme.accentGreen,
                          foregroundColor: Colors.black,
                        ),
                        icon: _capturing
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                              )
                            : const Icon(Icons.camera_alt),
                        label: Text(_capturing ? 'Capturing…' : 'Capture'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: _pickFromGallery,
                  icon: const Icon(Icons.photo_library_outlined),
                  label: const Text('Use gallery instead'),
                ),
                if (_error != null)
                  TextButton.icon(
                    onPressed: _start,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Try camera again'),
                  ),
              ] else
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _retake,
                        child: const Text('Retake'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _usePhoto,
                        style: FilledButton.styleFrom(
                          backgroundColor: AppTheme.accentGreen,
                          foregroundColor: Colors.black,
                        ),
                        icon: const Icon(Icons.check),
                        label: const Text('Use photo'),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}
