import 'package:flutter/material.dart';

final class LabeledValueRow extends StatelessWidget {
  const LabeledValueRow({
    required this.label,
    required this.value,
    this.bottomPadding = 12,
    super.key,
  });

  final String label;
  final String value;
  final double bottomPadding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: bottomPadding),
      child: SelectableText('$label: $value'),
    );
  }
}

final class LabeledValueBlock extends StatelessWidget {
  const LabeledValueBlock({
    required this.label,
    required this.value,
    super.key,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 4),
        SelectableText(value),
      ],
    );
  }
}
