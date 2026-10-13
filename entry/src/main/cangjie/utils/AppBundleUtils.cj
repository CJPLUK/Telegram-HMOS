package ohos_app_cangjie_entry.utils

import kit.LocalizationKit.*
import kit.AbilityKit.UIAbilityContext
import ohos.business_exception.BusinessException
import kit.PerformanceAnalysisKit.Hilog

/**
 * AppBundleUtils — 统一资源（rawfile）访问封装
 *
 * 对应 Telegram-iOS submodules/AppBundle（语义）：从应用 bundle / 资源目录
 * 读取随包打包的静态资源。鸿蒙侧等价能力为
 *   context.resourceManager.getRawFileContent(path): Array<UInt8>
 * （读取 resources/rawfile 目录下文件，cangjie-kb ohos.resourcemanager 实证）。
 *
 * 本工具收敛工程中散落的 rawfile 读取写法（main_ability.cj 提取 chat_bg、
 * auth/SplashPage.cj 提取 intro_*.png 等）的「拿 context → 取 resourceManager →
 * getRawFileContent」三段式，统一为一处薄封装，便于后续复用。
 *
 * 口径说明：
 *   - context 通过本包自持的 holder（_appBundleContext）获取，由 main_ability.cj
 *     onCreate 调 setAppBundleContext(this.context) 注册——与现有
 *     services.setGlobalAbilityContext 同款模式。之所以不复用
 *     services.getGlobalAbilityContext()：services 包反向 import 了 utils 包
 *     （AppLockService / RealMessageService 等），utils 再 import services 会触发
 *     cjpm 循环依赖。root 包 main_ability import utils 不构成环（utils 不 import root）。
 *   - getRawFileContent 失败抛 BusinessException（如 9001005 非法相对路径），
 *     全部 try/catch 兜住，拿不到 context / 读失败一律返回 None，不崩。
 *   - 文本读取按 UTF-8 解码（String.fromUtf8），与工程其余字节转字符串口径一致。
 *   - 顶层函数名加 appBundle 前缀，避开 utils 包级命名冲突（如 EmojiDetectUtils
 *     已有顶层 selfCheck）。
 */

// ===== context holder（main_ability 注册，避免反向 import services 的循环依赖） =====

private var _appBundleContext: Option<UIAbilityContext> = None

/**
 * 注册全局 UIAbilityContext，供 rawfile 读取使用。
 * 由 main_ability.cj 的 onCreate 调用：setAppBundleContext(this.context)。
 */
public func setAppBundleContext(ctx: UIAbilityContext): Unit {
    _appBundleContext = Some(ctx)
}

// ===== rawfile 二进制读取 =====

/**
 * 读取 resources/rawfile 目录下 path 对应文件的原始二进制内容。
 *
 * @param path rawfile 相对路径（如 "chat_bg_default.png"）。
 * @return Some(bytes) 读取成功；拿不到 context / 路径非法 / 读失败 → None。
 */
public func readRawFileBytes(path: String): Option<Array<UInt8>> {
    if (path.size == 0) {
        return None
    }
    let ctx: UIAbilityContext
    match (_appBundleContext) {
        case None =>
            Hilog.info(0, "CjTelegram", "[AppBundleUtils] readRawFileBytes: no ability context registered")
            return None
        case Some(c) => ctx = c
    }
    try {
        let rm = ctx.resourceManager
        let data = rm.getRawFileContent(path)
        return Some(data)
    } catch (e: BusinessException) {
        Hilog.info(0, "CjTelegram",
            "[AppBundleUtils] readRawFileBytes failed for ${path}: ${e.message}")
        return None
    } catch (_: Exception) {
        Hilog.info(0, "CjTelegram",
            "[AppBundleUtils] readRawFileBytes unexpected error for ${path}")
        return None
    }
}

// ===== rawfile 文本读取 =====

/**
 * 读取 rawfile 文件并按 UTF-8 解码为字符串。
 *
 * @param path rawfile 相对路径（如 "config.json"）。
 * @return Some(text) 读取并解码成功；读失败 / 解码失败 → None。
 */
public func readRawFileText(path: String): Option<String> {
    match (readRawFileBytes(path)) {
        case None => return None
        case Some(bytes) =>
            try {
                let text = String.fromUtf8(bytes)
                return Some(text)
            } catch (_: Exception) {
                Hilog.info(0, "CjTelegram",
                    "[AppBundleUtils] readRawFileText utf8 decode failed for ${path}")
                return None
            }
    }
}

// ===== 自检（结构性，纯逻辑） =====

/**
 * appBundleSelfCheck — 结构性自检。
 *
 * 注：真实 rawfile 读取需运行时（UIAbilityContext + ResourceManager + 打包资源），
 * 属非常驻能力，无法在纯逻辑单测里断言。此处只断言 API 在「未注册 context」与
 * 「空路径」退化路径下安全返回 None、不抛异常。
 */
public func appBundleSelfCheck(): Bool {
    // 空路径必返 None（不触达 context / resourceManager）
    match (readRawFileBytes("")) {
        case None => ()
        case Some(_) => return false
    }
    match (readRawFileText("")) {
        case None => ()
        case Some(_) => return false
    }
    // 在无注册 context 的环境下（如单测进程），非空路径也应安全返回 None 而非崩溃。
    // 若运行时已注册 context 且资源存在，此调用可能返回 Some——两种结果都不应抛异常，
    // 故此处仅验证调用不崩，不对返回值做强断言。
    let _ = readRawFileBytes("__appbundle_selfcheck_nonexistent__.bin")
    return true
}
