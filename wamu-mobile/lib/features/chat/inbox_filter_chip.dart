import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// Theme-aware inbox filter chip (All / Unread / …).
class InboxFilterChip extends StatelessWidget {
  const InboxFilterChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final unselectedFg = dark ? AppTheme.messengerText : const Color(0xFF111B21);
    final selectedBg = dark ? const Color(0xFF0A3D2E) : const Color(0xFFD7F5E5);
    final unselectedBg = dark ? AppTheme.messengerElevated : const Color(0xFFF0F2F5);

    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: FilterChip(
        label: Text(label),
        selected: selected,
        showCheckmark: false,
        onSelected: (_) => onTap(),
        labelStyle: TextStyle(
          color: selected ? AppTheme.accentGreen : unselectedFg,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          fontSize: 13,
        ),
        selectedColor: selectedBg,
        backgroundColor: unselectedBg,
        side: BorderSide.none,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}
