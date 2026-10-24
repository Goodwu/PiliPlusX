import { FlutterAbility, FlutterEngine } from '@ohos/flutter_ohos';
import type Want from '@ohos.app.ability.Want';
import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import { GeneratedPluginRegistrant } from '../plugins/GeneratedPluginRegistrant';
import HarmonyChannel, { HdrCapabilitiesChannel } from '../plugins/HarmonyChannel';
import window from '@ohos.window';

export default class EntryAbility extends FlutterAbility {
  harmonyChannel: HarmonyChannel = new HarmonyChannel()
  hdrCapabilitiesChannel: HdrCapabilitiesChannel = new HdrCapabilitiesChannel()
  wasFloatingWindow: boolean = false

  configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    GeneratedPluginRegistrant.registerWith(flutterEngine)
    flutterEngine.getPlugins()?.add(this.harmonyChannel);
    flutterEngine.getPlugins()?.add(this.hdrCapabilitiesChannel);
  }

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam) {
    super.onCreate(want, launchParam);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    super.onWindowStageCreate(windowStage)
    let w = windowStage.getMainWindowSync()
    w.on('windowStatusChange', (type) => {
      if (type == window.WindowStatusType.FLOATING && !this.wasFloatingWindow) {
        this.harmonyChannel.onFloatingWindowChange(true)
        this.wasFloatingWindow = true
      } else if (this.wasFloatingWindow && type != window.WindowStatusType.FLOATING) {
        this.harmonyChannel.onFloatingWindowChange(false)
        this.wasFloatingWindow = false
      }
    })
  }
}
