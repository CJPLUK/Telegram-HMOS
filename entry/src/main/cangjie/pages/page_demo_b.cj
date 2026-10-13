package ohos_app_cangjie_entry.pages

import kit.ArkUI.*
import ohos.arkui.state_macro_manage.*
import ohos_app_cangjie_entry.router.*

// 目标页：渲染时从 ParamStore 取回富参（takePending，取后清）。验证 SSOT §4 富参协议。
@HybridComponentEntry
@Component
class DemoB {
    @State
    var param: String = takePending("DemoB")

    public func build() {
        Column {
            Text("DemoB — received rich param via ParamStore:")
            Text(param)
            Button("back (CJ router)").onClick({
                evt => routerPop()
            })
        }
    }
}
