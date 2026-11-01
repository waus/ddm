part of '../mobile_layout.dart';

sealed class _MobileContactRow {
  const _MobileContactRow();
}

final class _MobileContactItemRow extends _MobileContactRow {
  const _MobileContactItemRow(this.contact);

  final ContactRecord contact;
}

final class _MobileContactSectionRow extends _MobileContactRow {
  const _MobileContactSectionRow(this.title);

  final String title;
}
