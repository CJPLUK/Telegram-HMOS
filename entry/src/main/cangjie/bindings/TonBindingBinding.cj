package ohos_app_cangjie_entry.bindings

import kit.PerformanceAnalysisKit.Hilog

/**
 * TonBindingBinding — TON 区块链钱包平台封装层
 *
 * 对应 Telegram-iOS submodules/TonBinding（使用 tonlib native 库实现链上操作）。
 *
 * 平台能力说明：
 *   HarmonyOS 无官方 TON SDK / tonlib 移植。本封装层分两类能力：
 *
 *   【已实现 — 纯逻辑，无网络依赖】
 *   - TON 地址校验（isValidTonAddress）：48 字符 base64url 格式检查
 *   - TON 地址格式化（formatTonAddress）：对应 iOS TonFormat.swift#formatTonAddress
 *   - TON 金额格式化（formatTonAmount）：nanoton → 可读小数点字符串
 *   - Stars ↔ TON 换算（convertStarsToTon / convertTonToStars）
 *
 *   【platform_gap — 需 tonlib / 链上通信，标为 deferred】
 *   - getWalletBalance：查询链上余额，需 tonlib liteserver 连接
 *   - sendTransfer：链上转账签名/广播，需私钥管理 + tonlib
 *   - importWallet / exportWalletKey：助记词/私钥管理，需 tonlib keygen
 *
 *   deferred 方法返回描述性错误字符串，供调用方做 UI 降级（如"此功能需链上钱包支持"）。
 *   接口契约完整保留，便于未来集成 TON SDK 时替换实现体。
 *
 * 参考 iOS 源：
 *   submodules/TelegramStringFormatting/Sources/TonFormat.swift
 *   submodules/TonBinding/BUILD（tonlib 编译入口）
 */

/**
 * TON 地址长度（base64url，48 字符，对应 iOS walletAddressLength = 48）
 */
public let TON_ADDRESS_LENGTH: Int32 = 48

/**
 * TON 金额单位：1 TON = 1,000,000,000 nanoton（nano = 1e-9）
 */
public let TON_NANO_PER_TON: Int64 = 1000000000

/**
 * 链上操作结果类型
 * Success: 操作成功，携带字符串结果（余额/txHash 等）
 * Deferred: 平台能力缺口，携带说明字符串
 * Error: 逻辑错误，携带错误描述
 */
public enum TonOperationResult {
    | Success(String)
    | Deferred(String)
    | Error(String)
}

/**
 * 钱包导入结果
 */
public enum TonWalletImportResult {
    | Success(String)
    | Deferred(String)
    | Error(String)
}

private var _tonBindingInstance: Option<TonBinding> = None

/**
 * 获取 TonBinding 单例
 */
public func getTonBinding(): TonBinding {
    match (_tonBindingInstance) {
        case Some(inst) => return inst
        case None =>
            let inst = TonBinding()
            _tonBindingInstance = Some(inst)
            return inst
    }
}

/**
 * TON 区块链钱包绑定封装
 */
public class TonBinding {

    /**
     * 校验 TON 钱包地址格式。
     *
     * 对应 iOS TonFormat.swift#isValidTonAddress。
     * TON 地址使用 base64url 编码，仅含 A-Z a-z 0-9 - _ =，长度 ≤ 48。
     * exactLength=true 时要求恰好 48 字符（完整地址）。
     *
     * @param address  待校验地址字符串
     * @param exactLength  true 时要求恰好 48 字符
     * @return true 表示格式有效
     */
    public func isValidTonAddress(address: String, exactLength: Bool): Bool {
        if (address.size > Int64(TON_ADDRESS_LENGTH)) {
            return false
        }
        let runes = address.toRuneArray()
        for (r in runes) {
            let code = UInt32(r)
            let isUpper = code >= 65 && code <= 90
            let isLower = code >= 97 && code <= 122
            let isDigit = code >= 48 && code <= 57
            let isDash = code == 45
            let isUnderscore = code == 95
            let isEquals = code == 61
            if (!isUpper && !isLower && !isDigit && !isDash && !isUnderscore && !isEquals) {
                return false
            }
        }
        if (exactLength && Int32(address.size) != TON_ADDRESS_LENGTH) {
            return false
        }
        return true
    }

    /**
     * 格式化 TON 钱包地址（在中点插入换行，分两行显示）。
     *
     * 对应 iOS TonFormat.swift#formatTonAddress：
     *   在 address.count / 2 处插入 "\n"。
     *
     * @param address  TON 地址字符串
     * @return 插入换行后的地址；长度 < 2 时原样返回
     */
    public func formatTonAddress(address: String): String {
        let runes = address.toRuneArray()
        if (runes.size < 2) {
            return address
        }
        let midPoint = runes.size / 2
        var result = ""
        for (i in 0..midPoint) {
            result = result + runes[i].toString()
        }
        result = result + "\n"
        for (i in midPoint..runes.size) {
            result = result + runes[i].toString()
        }
        return result
    }

    /**
     * 将 nanoton 数值格式化为可读的 TON 小数点字符串。
     *
     * 对应 iOS TonFormat.swift#formatTonAmountText。
     * 1 TON = 1,000,000,000 nanoton（9 位小数）。
     * 末尾零自动去除；整数部分无小数点时不显示小数点。
     * 负值在最前加 "-"；showPlus=true 时正值加 "+"。
     *
     * @param nanotons  nanoton 数量（可以为负）
     * @param decimalSeparator  小数点字符，默认 "."
     * @param showPlus  true 时正值前加 "+"
     * @param maxDecimalPositions  最多保留小数位数，None 表示不限制
     * @return 格式化后的金额字符串，如 "1.5"、"0.001"
     */
    public func formatTonAmount(nanotons: Int64, decimalSeparator: String, showPlus: Bool,
                                maxDecimalPositions: Option<Int32>): String {
        let absVal = if (nanotons < 0) { -nanotons } else { nanotons }
        var balanceText = absVal.toString()
        while (Int32(balanceText.size) < 10) {
            balanceText = "0" + balanceText
        }
        let sepRunes = decimalSeparator.toRuneArray()
        let sepChar = if (sepRunes.size > 0) { sepRunes[0].toString() } else { "." }
        let insertPos = balanceText.size - 9
        balanceText = balanceText[0..insertPos] + sepChar + balanceText[insertPos..]
        while (true) {
            if (balanceText.endsWith("0")) {
                let withoutLast = balanceText[0..balanceText.size - 1]
                if (withoutLast.endsWith(sepChar)) {
                    balanceText = withoutLast[0..withoutLast.size - sepChar.size]
                    break
                } else {
                    balanceText = withoutLast
                }
            } else {
                break
            }
        }
        match (maxDecimalPositions) {
            case Some(maxDec) =>
                let dotIdx = balanceText.indexOf(sepChar)
                match (dotIdx) {
                    case Some(pos) =>
                        let maxEnd = pos + sepChar.size + Int64(maxDec)
                        if (maxEnd < Int64(balanceText.size)) {
                            balanceText = balanceText[0..maxEnd]
                        }
                    case None => ()
                }
            case None => ()
        }
        if (nanotons < 0) {
            balanceText = "-" + balanceText
        } else if (showPlus) {
            balanceText = "+" + balanceText
        }
        return balanceText
    }

    /**
     * 将 Stars 金额换算为 nanoton。
     *
     * 对应 iOS TonFormat.swift#convertStarsToTon。
     * 换算公式：usdValue = stars * (starsUsdRate / 1000.0 / 100.0)
     *            tonNano = usdValue / tonUsdRate * 1e9
     *
     * @param starsValue  Stars 数量（整数部分）
     * @param tonUsdRate  TON/USD 汇率
     * @param starsUsdRate  Stars/USD 汇率（每千 Stars 的美分价值）
     * @return nanoton 数量
     */
    public func convertStarsToTon(starsValue: Int64, tonUsdRate: Float64, starsUsdRate: Float64): Int64 {
        let usdRate = starsUsdRate / 1000.0 / 100.0
        let usdValue = Float64(starsValue) * usdRate
        let tonNano = usdValue / tonUsdRate * Float64(TON_NANO_PER_TON)
        return Int64(tonNano)
    }

    /**
     * 将 nanoton 换算为 Stars 数量。
     *
     * 对应 iOS TonFormat.swift#convertTonToStars。
     *
     * @param nanotons  nanoton 数量
     * @param tonUsdRate  TON/USD 汇率
     * @param starsUsdRate  Stars/USD 汇率（每千 Stars 的美分价值）
     * @return Stars 整数数量
     */
    public func convertTonToStars(nanotons: Int64, tonUsdRate: Float64, starsUsdRate: Float64): Int64 {
        let usdRate = starsUsdRate / 1000.0 / 100.0
        let tonAmount = Float64(nanotons) / Float64(TON_NANO_PER_TON)
        let usdValue = tonAmount * tonUsdRate
        let stars = usdValue / usdRate
        return Int64(stars)
    }

    /**
     * 格式化 TON 金额为 USD 等价字符串（如 "$1.23"）。
     *
     * 对应 iOS TonFormat.swift#formatTonUsdValue。
     *
     * @param nanotons  nanoton 数量
     * @param divide    true 时除以 1e9 将 nanoton 转为 TON，false 时视为整数 TON
     * @param rate      USD 汇率
     * @return "$x.xx" 格式字符串
     */
    public func formatTonUsdValue(nanotons: Int64, divide: Bool, rate: Float64): String {
        let normalizedValue = if (divide) {
            Float64(nanotons) / Float64(TON_NANO_PER_TON)
        } else {
            Float64(nanotons)
        }
        let usdValue = normalizedValue * rate
        return "$" + formatFloat2Decimal(usdValue)
    }

    /**
     * [platform_gap/deferred] 查询 TON 钱包链上余额。
     *
     * 需要 tonlib liteserver 连接（ADNL 协议），当前 HarmonyOS 无可用实现。
     * 返回 Deferred 说明，调用方应展示"此功能需要链上钱包支持"等降级 UI。
     *
     * iOS 对应：tonlib sendRequest(BalanceRequest) + callback
     *
     * @param walletAddress  TON 钱包地址（48 字符 base64url）
     * @return TonOperationResult.Deferred 描述平台限制
     */
    public func getWalletBalance(walletAddress: String): TonOperationResult {
        Hilog.info(0, "CjTelegram", "[TonBinding] getWalletBalance: platform_gap, no tonlib on HarmonyOS")
        return TonOperationResult.Deferred("platform_gap: TON balance query requires tonlib/liteserver, not available on HarmonyOS")
    }

    /**
     * [platform_gap/deferred] 发起 TON 链上转账。
     *
     * 需要私钥/助记词管理 + tonlib 签名广播，当前 HarmonyOS 无可用实现。
     * 返回 Deferred，调用方应提示用户使用外部 TON 钱包完成转账。
     *
     * iOS 对应：tonlib sendRequest(TransferRequest) with keystore
     *
     * @param fromAddress  发送方地址
     * @param toAddress    接收方地址
     * @param nanotons     转账金额（nanoton）
     * @param comment      转账备注（可选）
     * @return TonOperationResult.Deferred 描述平台限制
     */
    public func sendTransfer(fromAddress: String, toAddress: String, nanotons: Int64, comment: String): TonOperationResult {
        Hilog.info(0, "CjTelegram", "[TonBinding] sendTransfer: platform_gap, no tonlib on HarmonyOS")
        return TonOperationResult.Deferred("platform_gap: TON transfer requires tonlib signing, not available on HarmonyOS")
    }

    /**
     * [platform_gap/deferred] 导入 TON 钱包（从助记词）。
     *
     * 需要 tonlib keygen（BIP39 / TON 词库），当前 HarmonyOS 无可用实现。
     *
     * iOS 对应：tonlib importKey(mnemonicList)
     *
     * @param mnemonicWords  助记词列表（通常 24 个单词）
     * @return TonWalletImportResult.Deferred 描述平台限制
     */
    public func importWalletFromMnemonic(mnemonicWords: Array<String>): TonWalletImportResult {
        Hilog.info(0, "CjTelegram", "[TonBinding] importWalletFromMnemonic: platform_gap, no tonlib on HarmonyOS")
        return TonWalletImportResult.Deferred("platform_gap: TON wallet import requires tonlib keygen, not available on HarmonyOS")
    }

    /**
     * [platform_gap/deferred] 导出 TON 钱包公钥。
     *
     * 需要 tonlib 密钥库访问，当前 HarmonyOS 无可用实现。
     *
     * @param walletAddress  钱包地址
     * @return TonOperationResult.Deferred 描述平台限制
     */
    public func exportWalletPublicKey(walletAddress: String): TonOperationResult {
        Hilog.info(0, "CjTelegram", "[TonBinding] exportWalletPublicKey: platform_gap, no tonlib on HarmonyOS")
        return TonOperationResult.Deferred("platform_gap: TON key export requires tonlib keystore, not available on HarmonyOS")
    }

    private func formatFloat2Decimal(value: Float64): String {
        let absVal = if (value < 0.0) { -value } else { value }
        let intPart = Int64(absVal)
        let fracPart = Int64((absVal - Float64(intPart)) * 100.0 + 0.5)
        let fracClamped = if (fracPart >= 100) { Int32(99) } else { Int32(fracPart) }
        let fracStr = if (fracClamped < 10) { "0" + fracClamped.toString() } else { fracClamped.toString() }
        let sign = if (value < 0.0) { "-" } else { "" }
        return sign + intPart.toString() + "." + fracStr
    }
}
