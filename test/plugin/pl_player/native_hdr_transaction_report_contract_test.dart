import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit_video/src/video_controller/hdr_transaction_report.dart';
import 'package:PiliPlus/plugin/pl_player/models/native_hdr_transaction.dart';

void main() {
  test('reads capability and activation from typed reports', () {
    const candidate = HdrTransactionReport(capable: true);
    const active = HdrTransactionReport(capable: true, active: true);

    expect(nativeHdrReportIsCapable(candidate), isTrue);
    expect(nativeHdrReportIsActive(candidate), isFalse);
    expect(nativeHdrReportIsCapable(active), isTrue);
    expect(nativeHdrReportIsActive(active), isTrue);
    expect(nativeHdrReportIsStale(active), isFalse);
  });

  test('stale typed reports cannot publish capability or active state', () {
    const staleCandidate = HdrTransactionReport(capable: true, stale: true);
    const staleActive = HdrTransactionReport(
      capable: true,
      active: true,
      stale: true,
    );

    expect(nativeHdrReportIsStale(staleCandidate), isTrue);
    expect(nativeHdrReportIsCapable(staleCandidate), isFalse);
    expect(nativeHdrReportIsActive(staleCandidate), isFalse);
    expect(nativeHdrReportIsCapable(staleActive), isFalse);
    expect(nativeHdrReportIsActive(staleActive), isFalse);
  });

  test(
    'keeps compatibility with legacy map and capability boolean results',
    () {
      expect(nativeHdrReportIsCapable(true), isTrue);
      expect(nativeHdrReportIsCapable(false), isFalse);
      // A legacy bool carries no activation evidence.
      expect(nativeHdrReportIsActive(true), isFalse);
      expect(
        nativeHdrReportIsCapable({'capable': true, 'active': false}),
        isTrue,
      );
      expect(
        nativeHdrReportIsActive({'capable': true, 'active': true}),
        isTrue,
      );
      expect(nativeHdrReportIsStale({'stale': true}), isTrue);
      expect(
        nativeHdrReportIsActive({'active': true, 'stale': true}),
        isFalse,
      );
      expect(nativeHdrReportIsCapable({'capable': 'true'}), isFalse);
    },
  );

  test('unknown and null report values fail closed', () {
    final values = <Object?>[null, Object(), 'active', 1];
    for (final value in values) {
      expect(nativeHdrReportIsCapable(value), isFalse, reason: '$value');
      expect(nativeHdrReportIsActive(value), isFalse, reason: '$value');
      expect(nativeHdrReportIsStale(value), isFalse, reason: '$value');
    }
  });

  test(
    'controller routes native reports through the typed compatibility helper',
    () {
      final source = File('lib/plugin/pl_player/controller.dart')
          .readAsStringSync();
      final transaction = source.substring(
        source.indexOf('Future<bool> _setHdrColorSpaceSerial('),
        source.indexOf('\n  Future<void> _applyHdrOutputParameters('),
      );

      expect(transaction, contains('nativeHdrReportIsCapable(created)'));
      expect(transaction, contains('nativeHdrReportIsStale(configured)'));
      expect(transaction, contains('nativeHdrReportIsActive(configured)'));
      expect(
        transaction,
        isNot(contains("configured = const <String, dynamic>{'active': true}")),
      );
    },
  );
}
