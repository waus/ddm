import 'package:flutter/material.dart';

final class MailboxSegmentLabel extends StatelessWidget {
  const MailboxSegmentLabel({
    required this.label,
    required this.unreadCount,
    super.key,
  });

  final String label;
  final int unreadCount;

  @override
  Widget build(BuildContext context) {
    final countSuffix = unreadCount > 0 ? ' ($unreadCount)' : '';
    return Text(
      '$label$countSuffix',
      style: TextStyle(
        fontWeight: unreadCount > 0 ? FontWeight.bold : null,
      ),
    );
  }
}
