package ohos_app_cangjie_entry.pages

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos_app_cangjie_entry.interop.*
import ohos_app_cangjie_entry.router.*

// 子包页面（验证：.pages 子包里的 @HybridComponentEntry 能否被 CJHybridComponent 嵌入，
// 且子包能 import 根包的 router/interop）。这是 Phase 3 183 页结构的前置确认。
@HybridComponentEntry
@Component
class DemoA {
    @State
    var echo: String = "(tap to call ArkTS capability)"

    public func build() {
        Column {
            Text("DemoA — CJ page in subpackage .pages")
            Button("open DemoB with rich param (CJ router)").onClick({
                evt => routerPush("DemoB", "{\"peerId\":42,\"title\":\"Saved Messages\"}")
            })
            Button("call ArkTS haptic (interop reversal)").onClick({
                evt => callArkAsync(HAPTIC_VIBRATE, "{\"ms\":50}", { r => echo = r })
            })
            Text(echo)
        }
    }
}
