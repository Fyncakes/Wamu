import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import 'emoji_catalog.dart';

/// Category grid of system emoji, the same approach WhatsApp uses.
class WamuEmojiPanel extends StatefulWidget {
  const WamuEmojiPanel({super.key, required this.onPick});

  final ValueChanged<String> onPick;

  @override
  State<WamuEmojiPanel> createState() => _WamuEmojiPanelState();
}

class _WamuEmojiPanelState extends State<WamuEmojiPanel> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final group = wamuEmojiGroups[_index.clamp(0, wamuEmojiGroups.length - 1)];
    return Column(
      children: [
        SizedBox(
          height: 36,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            itemCount: wamuEmojiGroups.length,
            separatorBuilder: (context, index) => const SizedBox(width: 6),
            itemBuilder: (_, i) {
              final selected = i == _index;
              return ChoiceChip(
                label: Text(wamuEmojiGroups[i].label),
                selected: selected,
                visualDensity: VisualDensity.compact,
                onSelected: (_) => setState(() => _index = i),
                selectedColor: AppTheme.accentGreen,
                labelStyle: TextStyle(
                  fontSize: 12,
                  color: selected ? Colors.black : null,
                  fontWeight: FontWeight.w600,
                ),
              );
            },
          ),
        ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 8,
            ),
            itemCount: group.glyphs.length,
            itemBuilder: (_, i) {
              final glyph = group.glyphs[i];
              return InkWell(
                onTap: () => widget.onPick(glyph),
                child: Center(child: Text(glyph, style: const TextStyle(fontSize: 24))),
              );
            },
          ),
        ),
      ],
    );
  }
}
