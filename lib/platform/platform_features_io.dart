import 'dart:io' show Platform;

const isWeb = false;
final isAndroid = Platform.isAndroid;
final isIOS = Platform.isIOS;
final isMacOS = Platform.isMacOS;
final isWindows = Platform.isWindows;
final isLinux = Platform.isLinux;
// The OHOS Flutter fork exposes its target through dart:io's operatingSystem
// string rather than a stable Platform.isOhos API.
final isOhos = Platform.operatingSystem.toLowerCase() == 'ohos';

final offlineDownload =
    Platform.isAndroid ||
    Platform.isIOS ||
    Platform.isMacOS ||
    Platform.isWindows ||
    Platform.isLinux;
final fileExport = !isOhos && !Platform.isFuchsia;
final tray = Platform.isMacOS || Platform.isWindows || Platform.isLinux;
final nativeWindow = Platform.isMacOS || Platform.isWindows || Platform.isLinux;
final backgroundAudio = !isOhos && (Platform.isAndroid || Platform.isIOS);
final pictureInPicture = !isOhos && (Platform.isAndroid || Platform.isIOS);
const screenshot = false;
// Native HDR remains explicitly opt-in and fail-closed until a backend
// reports an active output. Capability of the OS alone is not proof.
const nativeHdr = false;
