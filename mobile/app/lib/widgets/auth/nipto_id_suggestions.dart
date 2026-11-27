import 'package:flutter/material.dart';

/// Displays selectable Nipto ID alternatives during registration.
/// The caller must verify availability remotely before accepting a selection.
class NiptoIdSuggestions extends StatelessWidget {
  const NiptoIdSuggestions({
    super.key,
    required this.suggestions,
    required this.onSelected,
    this.selectedId,
  });

  final List<String> suggestions;
  final ValueChanged<String> onSelected;
  final String? selectedId;

  @override
  Widget build(BuildContext context) {
    if (suggestions.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Suggested Nipto IDs', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: suggestions.map((id) {
            final selected = id == selectedId;
            return ChoiceChip(
              label: Text('@$id'),
              selected: selected,
              onSelected: (_) => onSelected(id),
              tooltip: 'Choose @$id, then check availability',
            );
          }).toList(),
        ),
        const SizedBox(height: 4),
        Text(
          'Suggestions may already be taken. Check availability before continuing.',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}
