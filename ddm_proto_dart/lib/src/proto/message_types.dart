enum PowAlgorithm {
  vdfRsa(1);

  const PowAlgorithm(this.code);

  final int code;

  static PowAlgorithm fromCode(int code) {
    for (final item in PowAlgorithm.values) {
      if (item.code == code) {
        return item;
      }
    }
    throw FormatException('unsupported pow algorithm: $code');
  }
}

enum MessageType {
  plain(0, 'txt'),
  markdown(1, 'md'),
  binary(2, 'bin'),
  ack(3, 'ack');

  const MessageType(this.code, this.wireName);

  final int code;
  final String wireName;

  static MessageType fromCode(int code) {
    for (final item in MessageType.values) {
      if (item.code == code) {
        return item;
      }
    }
    throw FormatException('unsupported unencrypted message type: $code');
  }
}
