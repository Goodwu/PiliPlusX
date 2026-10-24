// Keep browser compilation isolated from native-only plugins.
export 'main_native.dart' if (dart.library.html) 'main_web.dart';
