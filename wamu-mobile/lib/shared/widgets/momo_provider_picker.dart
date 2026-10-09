import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// Shared MTN / Airtel Mobile Money picker used by cart, chat ORDER_CARD, and Orders retry.
class MomoProviderPicker extends StatelessWidget {
  const MomoProviderPicker({
    super.key,
    required this.value,
    required this.onChanged,
    this.enabled = true,
    this.compact = false,
  });

  final String value;
  final ValueChanged<String> onChanged;
  final bool enabled;
  final bool compact;

  static const providers = ['MTN', 'AIRTEL'];

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<String>(
      segments: [
        ButtonSegment(
          value: 'MTN',
          label: Text(compact ? 'MTN' : 'MTN MoMo'),
          icon: compact ? null : const Icon(Icons.phone_android, size: 16),
        ),
        ButtonSegment(
          value: 'AIRTEL',
          label: Text(compact ? 'Airtel' : 'Airtel Money'),
          icon: compact ? null : const Icon(Icons.phone_iphone, size: 16),
        ),
      ],
      selected: {value},
      onSelectionChanged: enabled
          ? (s) {
              if (s.isEmpty) return;
              onChanged(s.first);
            }
          : null,
      style: ButtonStyle(
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return Colors.black;
          }
          return null;
        }),
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return AppTheme.accentGreen;
          }
          return null;
        }),
      ),
    );
  }
}
