/// Reads the native HDR output transaction result across typed and legacy APIs.
///
/// New media-kit versions return a typed report with named boolean fields;
/// earlier versions returned maps, and `createNativeOutput` historically also
/// returned a boolean capability result.
bool nativeHdrReportIsStale(Object? report) =>
    _nativeHdrReportFieldIsTrue(report, 'stale');

bool nativeHdrReportIsCapable(Object? report) =>
    report == true ||
    (!nativeHdrReportIsStale(report) &&
        _nativeHdrReportFieldIsTrue(report, 'capable'));

bool nativeHdrReportIsActive(Object? report) =>
    !nativeHdrReportIsStale(report) &&
    _nativeHdrReportFieldIsTrue(report, 'active');

bool _nativeHdrReportFieldIsTrue(Object? report, String field) {
  if (report is Map) return report[field] == true;
  try {
    final dynamic typedReport = report;
    return switch (field) {
      'capable' => typedReport.capable == true,
      'active' => typedReport.active == true,
      'stale' => typedReport.stale == true,
      _ => false,
    };
  } on NoSuchMethodError {
    return false;
  }
}
