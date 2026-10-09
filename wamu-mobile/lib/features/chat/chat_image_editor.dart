import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../../core/theme/app_theme.dart';

class ChatImageEditResult {
  const ChatImageEditResult({required this.bytes, this.caption = ''});

  final Uint8List bytes;
  final String caption;
}

/// Full-screen editor: free drag/pan + pinch zoom under a crop window.
Future<ChatImageEditResult?> showChatImageEditor(
  BuildContext context, {
  required Uint8List bytes,
}) {
  return Navigator.of(context).push<ChatImageEditResult>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => ChatImageEditorScreen(bytes: bytes),
    ),
  );
}

class ChatImageEditorScreen extends StatefulWidget {
  const ChatImageEditorScreen({super.key, required this.bytes});

  final Uint8List bytes;

  @override
  State<ChatImageEditorScreen> createState() => _ChatImageEditorScreenState();
}

enum _AspectPreset { free, square, story, wide }

class _ChatImageEditorScreenState extends State<ChatImageEditorScreen> {
  final _captionCtrl = TextEditingController();
  late Uint8List _workingBytes;
  img.Image? _decoded;
  bool _busy = false;
  double _brightness = 0;
  double _contrast = 1;
  _AspectPreset _aspect = _AspectPreset.free;

  /// Free drag / pinch under the crop frame.
  double _scale = 1;
  Offset _offset = Offset.zero;
  double _startScale = 1;

  Size _viewport = Size.zero;

  @override
  void initState() {
    super.initState();
    _workingBytes = widget.bytes;
    _decoded = img.decodeImage(widget.bytes);
  }

  @override
  void dispose() {
    _captionCtrl.dispose();
    super.dispose();
  }

  Size get _imagePixelSize {
    final d = _decoded;
    if (d == null) return const Size(1, 1);
    return Size(d.width.toDouble(), d.height.toDouble());
  }

  /// How the image is laid out at scale=1, offset=0 (BoxFit.contain).
  Size _fittedSize(Size viewport) {
    final imgSize = _imagePixelSize;
    final scale = math.min(viewport.width / imgSize.width, viewport.height / imgSize.height);
    return Size(imgSize.width * scale, imgSize.height * scale);
  }

  Rect _cropRect(Size viewport) {
    // Keep a comfortable margin; aspect chips reshape the hole
    const margin = 24.0;
    var left = margin;
    var top = margin;
    var right = viewport.width - margin;
    var bottom = viewport.height - margin;
    var w = right - left;
    var h = bottom - top;

    double? target;
    switch (_aspect) {
      case _AspectPreset.free:
        target = null;
      case _AspectPreset.square:
        target = 1;
      case _AspectPreset.story:
        target = 3 / 4;
      case _AspectPreset.wide:
        target = 16 / 9;
    }
    if (target != null) {
      final current = w / h;
      if (current > target) {
        final nw = h * target;
        final pad = (w - nw) / 2;
        left += pad;
        right -= pad;
      } else {
        final nh = w / target;
        final pad = (h - nh) / 2;
        top += pad;
        bottom -= pad;
      }
    }
    return Rect.fromLTRB(left, top, right, bottom);
  }

  Future<void> _rotate() async {
    final src = _decoded;
    if (src == null) return;
    setState(() => _busy = true);
    await Future<void>.delayed(Duration.zero);
    final rotated = img.copyRotate(src, angle: 90);
    _decoded = rotated;
    _workingBytes = Uint8List.fromList(img.encodeJpg(rotated, quality: 92));
    _scale = 1;
    _offset = Offset.zero;
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _flip() async {
    final src = _decoded;
    if (src == null) return;
    setState(() => _busy = true);
    await Future<void>.delayed(Duration.zero);
    final flipped = img.flipHorizontal(src);
    _decoded = flipped;
    _workingBytes = Uint8List.fromList(img.encodeJpg(flipped, quality: 92));
    if (mounted) setState(() => _busy = false);
  }

  void _resetView() {
    setState(() {
      _scale = 1;
      _offset = Offset.zero;
      _brightness = 0;
      _contrast = 1;
      _aspect = _AspectPreset.free;
    });
  }

  Future<void> _applyAndSend() async {
    final src = _decoded;
    if (src == null || _viewport == Size.zero) return;
    setState(() => _busy = true);
    await Future<void>.delayed(Duration.zero);
    try {
      var out = src;
      final viewport = _viewport;
      final crop = _cropRect(viewport);
      final fitted = _fittedSize(viewport);

      // Image top-left in viewport at identity
      final baseLeft = (viewport.width - fitted.width) / 2;
      final baseTop = (viewport.height - fitted.height) / 2;

      // With scale around image center + pan offset
      final cx = baseLeft + fitted.width / 2;
      final cy = baseTop + fitted.height / 2;
      final scaledW = fitted.width * _scale;
      final scaledH = fitted.height * _scale;
      final imgLeft = cx - scaledW / 2 + _offset.dx;
      final imgTop = cy - scaledH / 2 + _offset.dy;

      // Map crop window → image pixel space
      final pxLeft = ((crop.left - imgLeft) / scaledW) * out.width;
      final pxTop = ((crop.top - imgTop) / scaledH) * out.height;
      final pxRight = ((crop.right - imgLeft) / scaledW) * out.width;
      final pxBottom = ((crop.bottom - imgTop) / scaledH) * out.height;

      var x = pxLeft.round().clamp(0, out.width - 1);
      var y = pxTop.round().clamp(0, out.height - 1);
      var w = (pxRight - pxLeft).round().clamp(1, out.width - x);
      var h = (pxBottom - pxTop).round().clamp(1, out.height - y);

      out = img.copyCrop(out, x: x, y: y, width: w, height: h);

      if (_brightness != 0 || (_contrast - 1).abs() > 0.01) {
        out = img.adjustColor(
          out,
          brightness: 1 + _brightness,
          contrast: _contrast,
        );
      }

      if (out.width > 1600 || out.height > 1600) {
        out = img.copyResize(
          out,
          width: out.width >= out.height ? 1600 : null,
          height: out.height > out.width ? 1600 : null,
        );
      }

      final bytes = Uint8List.fromList(img.encodeJpg(out, quality: 88));
      if (!mounted) return;
      Navigator.of(context).pop(
        ChatImageEditResult(bytes: bytes, caption: _captionCtrl.text.trim()),
      );
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not edit photo: $e')),
        );
      }
    }
  }

  void _onScaleStart(ScaleStartDetails details) {
    _startScale = _scale;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    setState(() {
      _scale = (_startScale * details.scale).clamp(1.0, 6.0);
      // Free drag / drop style pan
      _offset += details.focalPointDelta;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Edit photo'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : _resetView,
            child: const Text('Reset', style: TextStyle(color: Colors.white70)),
          ),
          TextButton(
            onPressed: _busy ? null : _applyAndSend,
            child: Text(
              'Done',
              style: TextStyle(
                color: _busy ? Colors.white38 : AppTheme.accentGreen,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                _viewport = Size(constraints.maxWidth, constraints.maxHeight);
                final fitted = _fittedSize(_viewport);
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    // Drag anywhere to move the photo
                    GestureDetector(
                      onScaleStart: _onScaleStart,
                      onScaleUpdate: _onScaleUpdate,
                      behavior: HitTestBehavior.opaque,
                      child: ColoredBox(
                        color: Colors.black,
                        child: Center(
                          child: Transform.translate(
                            offset: _offset,
                            child: Transform.scale(
                              scale: _scale,
                              child: ColorFiltered(
                                colorFilter: ColorFilter.matrix(
                                  _colorMatrix(_brightness, _contrast),
                                ),
                                child: Image.memory(
                                  _workingBytes,
                                  width: fitted.width,
                                  height: fitted.height,
                                  fit: BoxFit.fill,
                                  filterQuality: FilterQuality.medium,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    // Crop frame — ignores pointers so drag goes to image
                    IgnorePointer(
                      child: CustomPaint(
                        painter: _CropFramePainter(crop: _cropRect(_viewport)),
                      ),
                    ),
                    const Positioned(
                      left: 0,
                      right: 0,
                      bottom: 12,
                      child: Text(
                        'Drag to move · Pinch to zoom',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white70, fontSize: 13),
                      ),
                    ),
                    if (_busy)
                      const ColoredBox(
                        color: Color(0x66000000),
                        child: Center(
                          child: CircularProgressIndicator(color: AppTheme.accentGreen),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
          Container(
            color: const Color(0xFF111B21),
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 16),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      _ToolBtn(icon: Icons.rotate_90_degrees_ccw, label: 'Rotate', onTap: _busy ? null : _rotate),
                      _ToolBtn(icon: Icons.flip, label: 'Flip', onTap: _busy ? null : _flip),
                      _ToolBtn(
                        icon: Icons.zoom_in,
                        label: 'Zoom +',
                        onTap: _busy
                            ? null
                            : () => setState(() => _scale = (_scale * 1.15).clamp(1.0, 6.0)),
                      ),
                      _ToolBtn(
                        icon: Icons.zoom_out,
                        label: 'Zoom −',
                        onTap: _busy
                            ? null
                            : () => setState(() => _scale = (_scale / 1.15).clamp(1.0, 6.0)),
                      ),
                      _ToolBtn(
                        icon: Icons.center_focus_strong,
                        label: 'Center',
                        onTap: _busy ? null : () => setState(() => _offset = Offset.zero),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final e in [
                          (_AspectPreset.free, 'Free'),
                          (_AspectPreset.square, '1:1'),
                          (_AspectPreset.story, '3:4'),
                          (_AspectPreset.wide, '16:9'),
                        ])
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(
                              label: Text(e.$2),
                              selected: _aspect == e.$1,
                              onSelected: (_) => setState(() => _aspect = e.$1),
                              selectedColor: AppTheme.accentGreen,
                              labelStyle: TextStyle(
                                color: _aspect == e.$1 ? Colors.black : Colors.white70,
                                fontWeight: FontWeight.w600,
                              ),
                              backgroundColor: const Color(0xFF2A3942),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  _SliderRow(
                    icon: Icons.brightness_6,
                    label: 'Bright',
                    value: _brightness,
                    min: -0.35,
                    max: 0.35,
                    onChanged: (v) => setState(() => _brightness = v),
                  ),
                  _SliderRow(
                    icon: Icons.contrast,
                    label: 'Contrast',
                    value: _contrast,
                    min: 0.7,
                    max: 1.45,
                    onChanged: (v) => setState(() => _contrast = v),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _captionCtrl,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: 'Add a caption…',
                      hintStyle: const TextStyle(color: Colors.white54),
                      filled: true,
                      fillColor: const Color(0xFF2A3942),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      suffixIcon: IconButton(
                        tooltip: 'Send',
                        onPressed: _busy ? null : _applyAndSend,
                        icon: const Icon(Icons.send, color: AppTheme.accentGreen),
                      ),
                    ),
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _applyAndSend(),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  static List<double> _colorMatrix(double brightness, double contrast) {
    final b = brightness * 255;
    final c = contrast;
    final t = (1 - c) / 2 * 255;
    return <double>[
      c, 0, 0, 0, b + t,
      0, c, 0, 0, b + t,
      0, 0, c, 0, b + t,
      0, 0, 0, 1, 0,
    ];
  }
}

class _ToolBtn extends StatelessWidget {
  const _ToolBtn({required this.icon, required this.label, this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            children: [
              Icon(icon, color: onTap == null ? Colors.white24 : Colors.white, size: 22),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  color: onTap == null ? Colors.white24 : Colors.white70,
                  fontSize: 10,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final IconData icon;
  final String label;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: Colors.white70, size: 18),
        const SizedBox(width: 8),
        SizedBox(
          width: 64,
          child: Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: AppTheme.accentGreen,
              thumbColor: AppTheme.accentGreen,
              inactiveTrackColor: Colors.white24,
            ),
            child: Slider(value: value, min: min, max: max, onChanged: onChanged),
          ),
        ),
      ],
    );
  }
}

class _CropFramePainter extends CustomPainter {
  _CropFramePainter({required this.crop});

  final Rect crop;

  @override
  void paint(Canvas canvas, Size size) {
    final dim = Paint()..color = const Color(0x99000000);
    final border = Paint()
      ..color = AppTheme.accentGreen
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    final hole = Path()
      ..addRect(Offset.zero & size)
      ..addRect(crop)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(hole, dim);
    canvas.drawRect(crop, border);

    final guide = Paint()
      ..color = Colors.white24
      ..strokeWidth = 1;
    final w = crop.width;
    final h = crop.height;
    canvas.drawLine(Offset(crop.left + w / 3, crop.top), Offset(crop.left + w / 3, crop.bottom), guide);
    canvas.drawLine(Offset(crop.left + 2 * w / 3, crop.top), Offset(crop.left + 2 * w / 3, crop.bottom), guide);
    canvas.drawLine(Offset(crop.left, crop.top + h / 3), Offset(crop.right, crop.top + h / 3), guide);
    canvas.drawLine(Offset(crop.left, crop.top + 2 * h / 3), Offset(crop.right, crop.top + 2 * h / 3), guide);

    // Corner handles (visual)
    final handle = Paint()..color = AppTheme.accentGreen;
    const s = 14.0;
    for (final p in [crop.topLeft, crop.topRight, crop.bottomLeft, crop.bottomRight]) {
      canvas.drawCircle(p, 4, handle);
    }
    canvas.drawRect(Rect.fromLTWH(crop.left, crop.top, s, 3), handle);
    canvas.drawRect(Rect.fromLTWH(crop.left, crop.top, 3, s), handle);
    canvas.drawRect(Rect.fromLTWH(crop.right - s, crop.top, s, 3), handle);
    canvas.drawRect(Rect.fromLTWH(crop.right - 3, crop.top, 3, s), handle);
    canvas.drawRect(Rect.fromLTWH(crop.left, crop.bottom - 3, s, 3), handle);
    canvas.drawRect(Rect.fromLTWH(crop.left, crop.bottom - s, 3, s), handle);
    canvas.drawRect(Rect.fromLTWH(crop.right - s, crop.bottom - 3, s, 3), handle);
    canvas.drawRect(Rect.fromLTWH(crop.right - 3, crop.bottom - s, 3, s), handle);
  }

  @override
  bool shouldRepaint(covariant _CropFramePainter oldDelegate) => oldDelegate.crop != crop;
}
