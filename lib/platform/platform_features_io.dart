import 'dart:io' show Platform;

const isWeb = false;
final isAndroid = Platform.isAndroid;
final isIOS = Platform.isIOS;
final isMacOS = Platform.isMacOS;
final isWindows = Platform.isWindows;
final isLinux = Platform.isLinux;

final offlineDownload =
    Platform.isAndroid ||
    Platform.isIOS ||
    Platform.isMacOS ||
    Platform.isWindows ||
    Platform.isLinux;
final fileExport = !Platform.isFuchsia;
final tray = Platform.isMacOS || Platform.isWindows || Platform.isLinux;
final nativeWindow = Platform.isMacOS || Platform.isWindows || Platform.isLinux;
final backgroundAudio = Platform.isAndroid || Platform.isIOS;
final pictureInPicture = Platform.isAndroid || Platform.isIOS;
const screenshot = false;
// Native HDR remains explicitly opt-in and fail-closed until a backend
// reports an active output. Capability of the OS alone is not proof.
const nativeHdr = false;
