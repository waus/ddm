import 'package:flutter/material.dart';

const List<Duration> messageTtlOptions = <Duration>[
  Duration(hours: 1),
  Duration(hours: 2),
  Duration(hours: 3),
  Duration(hours: 6),
  Duration(hours: 12),
  Duration(hours: 24),
  Duration(days: 2),
  Duration(days: 3),
  Duration(days: 5),
  Duration(days: 7),
  Duration(days: 10),
  Duration(days: 14),
  Duration(days: 21),
  Duration(days: 30),
];

String formatMessageTtl(Duration value) {
  if (value.inHours < 24) {
    return '${value.inHours}H';
  }
  return '${value.inDays}D';
}

final class MessageTtlField extends StatefulWidget {
  const MessageTtlField({
    required this.value,
    required this.onChanged,
    super.key,
  });

  final Duration value;
  final ValueChanged<Duration> onChanged;

  @override
  State<MessageTtlField> createState() => _MessageTtlFieldState();
}

final class _MessageTtlFieldState extends State<MessageTtlField> {
  @override
  Widget build(BuildContext context) {
    final currentIndex = messageTtlOptions.indexOf(widget.value);
    final sliderIndex = currentIndex < 0 ? 0 : currentIndex;
    return Row(
      children: [
        Text(
          'TTL:',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Slider(
            value: sliderIndex.toDouble(),
            min: 0,
            max: (messageTtlOptions.length - 1).toDouble(),
            divisions: messageTtlOptions.length - 1,
            label: formatMessageTtl(widget.value),
            onChanged: (value) {
              widget.onChanged(messageTtlOptions[value.round()]);
            },
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(
          width: 40,
          child: Text(
            formatMessageTtl(widget.value),
            textAlign: TextAlign.right,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
      ],
    );
  }
}
