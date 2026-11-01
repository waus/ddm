part of '../mobile_layout.dart';

final class _MobileScreenBody extends StatelessWidget {
  const _MobileScreenBody({
    required this.tab,
    required this.state,
    required this.controller,
    required this.readState,
  });

  final _MobileTab tab;
  final AppState state;
  final AppController controller;
  final AppState Function() readState;

  @override
  Widget build(BuildContext context) {
    switch (tab) {
      case _MobileTab.messages:
        return _MobileMessagesScreen(
          state: state,
          controller: controller,
        );
      case _MobileTab.contacts:
        return _MobileContactsScreen(
          state: state,
          controller: controller,
          readState: readState,
        );
      case _MobileTab.account:
        return _MobileAccountScreen(
          state: state,
          controller: controller,
        );
      case _MobileTab.settings:
        return _MobileSettingsScreen(state: state);
    }
  }
}
