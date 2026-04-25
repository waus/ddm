import 'package:flutter/material.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';

final class AccountQrCode extends StatelessWidget {
  const AccountQrCode({
    required this.address,
    this.maxSize = 260,
    super.key,
  });

  final String address;
  final double maxSize;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxSize),
      child: AspectRatio(
        aspectRatio: 1,
        child: PrettyQrView.data(
          data: address,
          decoration: PrettyQrDecoration(
            background: colorScheme.surface,
            shape: PrettyQrSquaresSymbol(
              color: colorScheme.onSurface,
              rounding: 0.35,
            ),
            quietZone: PrettyQrQuietZone.standard,
          ),
        ),
      ),
    );
  }
}
