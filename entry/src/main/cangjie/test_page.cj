package ohos_app_cangjie_entry

import kit.ArkUI.Text
import kit.ArkUI.Button
import kit.ArkUI.Column
import kit.ArkUI.CustomView
import kit.ArkUI.LocalStorage
import kit.ArkUI.ObservedProperty
import kit.ArkUI.SubscriberManager
import kit.ArkUI.ViewStackProcessor
import kit.ArkUI.CJPageEntry
import kit.ArkUI.HybridComponentBase
import ohos.arkui.state_macro_manage.State
import ohos.arkui.state_macro_manage.Component
import ohos.arkui.state_macro_manage.HybridComponentEntry

@HybridComponentEntry
@Component
class TestPage {
    @State
    var msg: String = "Hello"

    public func build() {
        Column {
            Text(msg)
            Button("click to change Text").onClick ({
                evt => msg = "world"
            })
        }
    }
}
