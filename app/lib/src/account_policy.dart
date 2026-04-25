import 'package:ddm_proto_dart/ddm_proto_dart.dart';
import 'package:flutter/material.dart';

extension AccountPolicyView on AccountRecord {
  bool get isSilent => !Address.fromText(address).requiresAck;
}

final class AccountTitle extends StatelessWidget {
  const AccountTitle({
    required this.name,
    required this.isSilent,
    required this.style,
    super.key,
  });

  final String name;
  final bool isSilent;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    if (!isSilent) {
      return Text(name, style: style);
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.visibility_off_outlined,
          size: style?.fontSize,
          color: style?.color,
        ),
        const SizedBox(width: 8),
        Flexible(child: Text(name, style: style)),
      ],
    );
  }
}
