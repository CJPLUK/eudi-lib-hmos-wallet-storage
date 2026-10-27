package ohos_app_cangjie_entry

import kit.ArkUI.LengthProp
import kit.ArkUI.Column
import kit.ArkUI.Row
import kit.ArkUI.Text
import kit.ArkUI.Button
import kit.ArkUI.CustomView
import kit.ArkUI.CJEntry
import kit.ArkUI.loadNativeView
import kit.ArkUI.FontWeight
import kit.ArkUI.SubscriberManager
import kit.ArkUI.ObservedProperty
import kit.ArkUI.LocalStorage
import kit.AbilityKit.UIAbilityContext
import ohos.arkui.state_macro_manage.Entry
import ohos.arkui.state_macro_manage.Component
import ohos.arkui.state_macro_manage.State
import ohos_app_cangjie_eudi_cjwallet_storage.runWalletStorageDemo

// Package-level context holder — set by MainAbility.onCreate.
// Pattern: canonical UIAbilityContext injection via global var
// (see UIAbility组件基本用法, cangjie-kb).
var globalContext: ?UIAbilityContext = None

// Resolve the package-level UIAbilityContext.
//
// During `aa test`, the OpenHarmonyTestRunner launches EntryAbility
// asynchronously (d.startAbility) and immediately spawns the test thread.
// MainAbility.onCreate — which assigns globalContext — may therefore not have
// run yet when the first device test cases call getContext(). Without waiting,
// those early cases hit None.getOrThrow() -> NoneValueException and are counted
// as flaky errors (the count floats with scheduling). We wait, with a bounded
// budget, for onCreate to populate the global before giving up.
func getContext(): UIAbilityContext {
    match (globalContext) {
        case Some(c) => return c
        case None => ()
    }
    // Up to ~5s (100 * 50ms) for EntryAbility.onCreate to run.
    var attempt: Int64 = 0
    while (attempt < 100) {
        sleep(Duration.millisecond * 50)
        match (globalContext) {
            case Some(c) => return c
            case None => ()
        }
        attempt++
    }
    return globalContext.getOrThrow()
}

@Entry
@Component
class EntryView {
    @State
    var resultText: String = "Press the button to run the Wallet-Storage demo."

    func build() {
        Row {
            Column {
                Text(this.resultText)
                    .fontSize(16)
                    .fontWeight(FontWeight.Regular)

                Button("Run Wallet-Storage Demo")
                    .fontSize(16)
                    .onClick({
                        evt =>
                        let ctx = getContext()
                        let result = runWalletStorageDemo(ctx)
                        this.resultText = result
                    })
            }.width(100.percent)
        }.height(100.percent)
    }
}
