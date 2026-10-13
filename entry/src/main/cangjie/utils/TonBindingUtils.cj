package ohos_app_cangjie_entry.utils

import ohos_app_cangjie_entry.bindings.{getTonBinding, TonOperationResult, TonWalletImportResult}
import kit.PerformanceAnalysisKit.Hilog

/**
 * TonBindingUtils — TON 区块链钱包高层工具接口
 *
 * 对应 Telegram-iOS submodules/TonBinding 上层调用封装 +
 *   submodules/TelegramStringFormatting/Sources/TonFormat.swift 工具函数。
 *
 * 提供：
 *   - validateTonAddress          地址格式验证（纯逻辑，完整实现）
 *   - formatTonAddress            地址换行格式化（纯逻辑，完整实现）
 *   - formatTonAmountString       nanoton → 可读字符串（纯逻辑，完整实现）
 *   - formatTonUsdString          nanoton → USD 等价字符串（纯逻辑，完整实现）
 *   - starsToTon / tonToStars     Stars ↔ TON 换算（纯逻辑，完整实现）
 *   - queryWalletBalance          链上余额查询（platform_gap/deferred）
 *   - performTransfer             链上转账（platform_gap/deferred）
 *   - importWallet                钱包导入（platform_gap/deferred）
 *
 * platform_gap 说明：
 *   链上操作（余额/转账/导入）依赖 tonlib native 库，该库未移植到 HarmonyOS。
 *   这些方法返回 TonOperationResult.Deferred 描述原因，调用方应展示相应降级 UI
 *   （如"请使用外部 TON 钱包"或"此功能暂不支持"）。
 */

/**
 * 验证 TON 钱包地址格式。
 *
 * 对应 iOS TonFormat.swift#isValidTonAddress。
 * 有效地址：仅含 A-Z a-z 0-9 - _ =，长度 ≤ 48；
 * exactLength=true 时要求恰好 48 字符（完整地址校验）。
 *
 * @param address      待校验地址
 * @param exactLength  是否要求精确 48 字符
 * @return true 表示格式有效
 */
public func validateTonAddress(address: String, exactLength: Bool): Bool {
    return getTonBinding().isValidTonAddress(address, exactLength)
}

/**
 * 格式化 TON 钱包地址（中点插入换行）。
 *
 * 对应 iOS TonFormat.swift#formatTonAddress。
 * 在地址中点插入 "\n"，便于 UI 两行显示完整地址。
 *
 * @param address  TON 地址字符串
 * @return 插入换行后的地址字符串
 */
public func formatTonAddress(address: String): String {
    return getTonBinding().formatTonAddress(address)
}

/**
 * 将 nanoton 数值格式化为可读 TON 金额字符串。
 *
 * 对应 iOS TonFormat.swift#formatTonAmountText。
 * 示例：1500000000 → "1.5"；500000 → "0.0005"；-1000000000 → "-1"
 *
 * @param nanotons           nanoton 数量（可为负）
 * @param decimalSeparator   小数点字符，默认 "."
 * @param showPlus           正值是否显示 "+"
 * @param maxDecimalPositions  最多保留小数位数，None 不限制
 * @return 格式化金额字符串
 */
public func formatTonAmountString(nanotons: Int64, decimalSeparator: String, showPlus: Bool,
                                   maxDecimalPositions: Option<Int32>): String {
    return getTonBinding().formatTonAmount(nanotons, decimalSeparator, showPlus, maxDecimalPositions)
}

/**
 * 将 nanoton 格式化为 USD 等价字符串（"$x.xx"）。
 *
 * 对应 iOS TonFormat.swift#formatTonUsdValue。
 *
 * @param nanotons  nanoton 数量
 * @param divide    true 时将 nanoton 换算为 TON 再乘汇率；false 时视为整数 TON
 * @param rate      TON/USD 汇率
 * @return "$x.xx" 格式字符串
 */
public func formatTonUsdString(nanotons: Int64, divide: Bool, rate: Float64): String {
    return getTonBinding().formatTonUsdValue(nanotons, divide, rate)
}

/**
 * 将 Stars 数量换算为 nanoton。
 *
 * 对应 iOS TonFormat.swift#convertStarsToTon。
 *
 * @param starsValue    Stars 数量
 * @param tonUsdRate    TON/USD 汇率
 * @param starsUsdRate  Stars/USD 汇率（每千 Stars 的美分价值）
 * @return nanoton 数量
 */
public func starsToTon(starsValue: Int64, tonUsdRate: Float64, starsUsdRate: Float64): Int64 {
    return getTonBinding().convertStarsToTon(starsValue, tonUsdRate, starsUsdRate)
}

/**
 * 将 nanoton 换算为 Stars 数量。
 *
 * 对应 iOS TonFormat.swift#convertTonToStars。
 *
 * @param nanotons      nanoton 数量
 * @param tonUsdRate    TON/USD 汇率
 * @param starsUsdRate  Stars/USD 汇率（每千 Stars 的美分价值）
 * @return Stars 整数数量
 */
public func tonToStars(nanotons: Int64, tonUsdRate: Float64, starsUsdRate: Float64): Int64 {
    return getTonBinding().convertTonToStars(nanotons, tonUsdRate, starsUsdRate)
}

/**
 * [platform_gap/deferred] 查询 TON 钱包链上余额。
 *
 * 需要 tonlib liteserver 连接，HarmonyOS 无可用实现。
 * 返回 TonOperationResult.Deferred，调用方应展示相应降级 UI。
 *
 * iOS 对应：tonlib BalanceRequest / getAccountState
 *
 * @param walletAddress  TON 钱包地址
 * @return TonOperationResult
 */
public func queryWalletBalance(walletAddress: String): TonOperationResult {
    if (!validateTonAddress(walletAddress, false)) {
        Hilog.info(0, "CjTelegram", "[TonBindingUtils] queryWalletBalance: invalid address format")
        return TonOperationResult.Error("Invalid TON address format")
    }
    return getTonBinding().getWalletBalance(walletAddress)
}

/**
 * [platform_gap/deferred] 发起 TON 链上转账。
 *
 * 需要 tonlib 签名/广播能力，HarmonyOS 无可用实现。
 * 调用方应提示用户通过外部 TON 钱包完成转账。
 *
 * iOS 对应：tonlib TransferRequest
 *
 * @param fromAddress  发送方钱包地址
 * @param toAddress    接收方钱包地址
 * @param nanotons     转账金额（nanoton，需 > 0）
 * @param comment      转账备注（空字符串表示无备注）
 * @return TonOperationResult
 */
public func performTransfer(fromAddress: String, toAddress: String, nanotons: Int64, comment: String): TonOperationResult {
    if (!validateTonAddress(fromAddress, false)) {
        return TonOperationResult.Error("Invalid sender TON address")
    }
    if (!validateTonAddress(toAddress, false)) {
        return TonOperationResult.Error("Invalid recipient TON address")
    }
    if (nanotons <= 0) {
        return TonOperationResult.Error("Transfer amount must be positive")
    }
    return getTonBinding().sendTransfer(fromAddress, toAddress, nanotons, comment)
}

/**
 * [platform_gap/deferred] 从助记词导入 TON 钱包。
 *
 * 需要 tonlib keygen，HarmonyOS 无可用实现。
 *
 * iOS 对应：tonlib importKey(mnemonicList)
 *
 * @param mnemonicWords  助记词数组（通常 24 个单词）
 * @return TonWalletImportResult
 */
public func importWallet(mnemonicWords: Array<String>): TonWalletImportResult {
    if (mnemonicWords.size == 0) {
        return TonWalletImportResult.Error("Mnemonic word list cannot be empty")
    }
    return getTonBinding().importWalletFromMnemonic(mnemonicWords)
}

/**
 * [platform_gap/deferred] 导出 TON 钱包公钥。
 *
 * 需要 tonlib keystore，HarmonyOS 无可用实现。
 *
 * @param walletAddress  钱包地址
 * @return TonOperationResult
 */
public func exportWalletPublicKey(walletAddress: String): TonOperationResult {
    if (!validateTonAddress(walletAddress, false)) {
        return TonOperationResult.Error("Invalid TON address format")
    }
    return getTonBinding().exportWalletPublicKey(walletAddress)
}
