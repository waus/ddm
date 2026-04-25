import 'package:ddm_proto_dart/ddm_proto_dart.dart';
import 'package:flutter/material.dart';

IconData mailboxIcon(Mailbox mailbox) {
  switch (mailbox) {
    case Mailbox.inbox:
      return Icons.inbox_outlined;
    case Mailbox.outbox:
      return Icons.send_outlined;
  }
}
