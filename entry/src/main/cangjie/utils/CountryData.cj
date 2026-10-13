package ohos_app_cangjie_entry.utils

import std.collection.ArrayList
import std.collection.HashMap
import std.sort.*
import std.unicode.*

/**
 * 国家 / 拨号代码数据资产
 *
 * D4.4 结构性移植（diag-suite_auth_login-TC-0007 第 4 轮结论 M1）：本文件的国家表
 * 已从自编近似表（223 行、无 pattern 列、缺 166 个拨号代码、32 条已录 pattern 与
 * 源侧不符、无 888/FT、国旗硬编码、名称自拟如 "China mainland"）整体替换为对
 * submodules/TelegramUI/Resources/PhoneCountries.txt（236 行 / 233 个拨号代码）的
 * 机械转录，见 phoneCountriesTable()。原自编表已整体删除，不保留其任何一行。
 */

/**
 * 唯一数据源：机械转录自 submodules/TelegramUI/Resources/PhoneCountries.txt
 * （236 行），逐行对应，不手工增删改行；每行四列 [code, iso2, pattern, name]，
 * 与源文件字段顺序一致（源侧 loadCountryCodes 用 ";" 分隔同样的四段）。
 *
 * 顺序保持源文件原序（不按 name/iso2 重排）—— 这是 lookupCountryIdByNumber /
 * lookupPatternByNumber 正确性的前提：源侧 countryCodesByPrefix 按文件顺序
 * "后写覆盖"（AuthorizationSequenceCountrySelectionController.swift:62），文件把
 * US（第 34 行）排在 CA（第 35 行）之前正是为了让同价拨号代码 "1" 最终以 CA 结尾
 * 覆盖，得到 "+1 默认 Canada"；RU/KZ（116/117 行）同理产生 "+7 默认 Kazakhstan"。
 * 若重排此表，这些源侧既定默认值会跟着改变。
 *
 * pattern 为空字符串表示源侧该国当前无 mask（源侧对应 code.patterns 为空数组，
 * mask == nil）——保留空串，不得杜撰默认 pattern（M1 边界约束）。
 *
 * 如源文件未来更新，只能重新对整表机械转录，不允许挑行增删改。
 */
private func phoneCountriesTable(): ArrayList<Array<String>> {
    let t = ArrayList<Array<String>>()
    t.add(["376", "AD", "XX XX XX", "Andorra"])
    t.add(["971", "AE", "XX XXX XXXX", "United Arab Emirates"])
    t.add(["93", "AF", "XXX XXX XXX", "Afghanistan"])
    t.add(["1268", "AG", "XXX XXXX", "Antigua & Barbuda"])
    t.add(["1264", "AI", "XXX XXXX", "Anguilla"])
    t.add(["355", "AL", "XX XXX XXXX", "Albania"])
    t.add(["374", "AM", "XX XXX XXX", "Armenia"])
    t.add(["244", "AO", "XXX XXX XXX", "Angola"])
    t.add(["54", "AR", "", "Argentina"])
    t.add(["1684", "AS", "XXX XXXX", "American Samoa"])
    t.add(["43", "AT", "XXX XXXXXX", "Austria"])
    t.add(["61", "AU", "X XXXX XXXX", "Australia"])
    t.add(["297", "AW", "XXX XXXX", "Aruba"])
    t.add(["994", "AZ", "XX XXX XXXX", "Azerbaijan"])
    t.add(["387", "BA", "XX XXX XXX", "Bosnia & Herzegovina"])
    t.add(["1246", "BB", "XXX XXXX", "Barbados"])
    t.add(["880", "BD", "XX XXX XXX", "Bangladesh"])
    t.add(["32", "BE", "XXX XX XX XX", "Belgium"])
    t.add(["226", "BF", "XX XX XX XX", "Burkina Faso"])
    t.add(["359", "BG", "", "Bulgaria"])
    t.add(["973", "BH", "XXXX XXXX", "Bahrain"])
    t.add(["257", "BI", "XX XX XXXX", "Burundi"])
    t.add(["229", "BJ", "XX XXX XXX", "Benin"])
    t.add(["1441", "BM", "XXX XXXX", "Bermuda"])
    t.add(["673", "BN", "XXX XXXX", "Brunei Darussalam"])
    t.add(["591", "BO", "X XXX XXXX", "Bolivia"])
    t.add(["599", "BQ", "", "Bonaire, Sint Eustatius & Saba"])
    t.add(["55", "BR", "XX XXXXX XXXX", "Brazil"])
    t.add(["1242", "BS", "XXX XXXX", "Bahamas"])
    t.add(["975", "BT", "XX XXX XXX", "Bhutan"])
    t.add(["267", "BW", "XX XXX XXX", "Botswana"])
    t.add(["375", "BY", "XX XXX XXXX", "Belarus"])
    t.add(["501", "BZ", "", "Belize"])
    t.add(["1", "US", "XXX XXX XXXX", "United States"])
    t.add(["1", "CA", "XXX XXX XXXX", "Canada"])
    t.add(["243", "CD", "XX XXX XXXX", "Congo (Dem. Rep.)"])
    t.add(["236", "CF", "XX XX XX XX", "Central African Rep."])
    t.add(["242", "CG", "XX XXX XXXX", "Congo (Rep.)"])
    t.add(["41", "CH", "XX XXX XXXX", "Switzerland"])
    t.add(["225", "CI", "XX XX XX XXXX", "Côte d'Ivoire"])
    t.add(["682", "CK", "", "Cook Islands"])
    t.add(["56", "CL", "X XXXX XXXX", "Chile"])
    t.add(["237", "CM", "XXXX XXXX", "Cameroon"])
    t.add(["86", "CN", "XXX XXXX XXXX", "China"])
    t.add(["57", "CO", "XXX XXX XXXX", "Colombia"])
    t.add(["506", "CR", "XXXX XXXX", "Costa Rica"])
    t.add(["53", "CU", "X XXX XXXX", "Cuba"])
    t.add(["238", "CV", "XXX XXXX", "Cape Verde"])
    t.add(["599", "CW", "", "Curaçao"])
    t.add(["357", "CY", "XXXX XXXX", "Cyprus"])
    t.add(["420", "CZ", "XXX XXX XXX", "Czech Republic"])
    t.add(["49", "DE", "", "Germany"])
    t.add(["253", "DJ", "XX XX XX XX", "Djibouti"])
    t.add(["45", "DK", "XXXX XXXX", "Denmark"])
    t.add(["1767", "DM", "XXX XXXX", "Dominica"])
    t.add(["1809", "DO", "XXX XXXX", "Dominican Rep."])
    t.add(["1829", "DO", "XXX XXXX", "Dominican Rep."])
    t.add(["1849", "DO", "XXX XXXX", "Dominican Rep."])
    t.add(["213", "DZ", "XXX XX XX XX", "Algeria"])
    t.add(["593", "EC", "XX XXX XXXX", "Ecuador"])
    t.add(["372", "EE", "XXXX XXX", "Estonia"])
    t.add(["20", "EG", "XX XXXX XXXX", "Egypt"])
    t.add(["291", "ER", "X XXX XXX", "Eritrea"])
    t.add(["34", "ES", "XXX XXX XXX", "Spain"])
    t.add(["251", "ET", "XX XXX XXX", "Ethiopia"])
    t.add(["358", "FI", "", "Finland"])
    t.add(["679", "FJ", "XXX XXXX", "Fiji"])
    t.add(["500", "FK", "", "Falkland Islands"])
    t.add(["691", "FM", "", "Micronesia"])
    t.add(["298", "FO", "XXX XXX", "Faroe Islands"])
    t.add(["33", "FR", "X XX XX XX XX", "France"])
    t.add(["241", "GA", "X XX XX XX", "Gabon"])
    t.add(["44", "GB", "XXXX XXXXXX", "United Kingdom"])
    t.add(["1473", "GD", "XXX XXXX", "Grenada"])
    t.add(["995", "GE", "XXX XXX XXX", "Georgia"])
    t.add(["594", "GF", "", "French Guiana"])
    t.add(["233", "GH", "XX XXX XXXX", "Ghana"])
    t.add(["350", "GI", "XXXX XXXX", "Gibraltar"])
    t.add(["299", "GL", "XXX XXX", "Greenland"])
    t.add(["220", "GM", "XXX XXXX", "Gambia"])
    t.add(["224", "GN", "XXX XXX XXX", "Guinea"])
    t.add(["590", "GP", "XXX XX XX XX", "Guadeloupe"])
    t.add(["240", "GQ", "XXX XXX XXX", "Equatorial Guinea"])
    t.add(["30", "GR", "XXX XXX XXXX", "Greece"])
    t.add(["502", "GT", "X XXX XXXX", "Guatemala"])
    t.add(["1671", "GU", "XXX XXXX", "Guam"])
    t.add(["245", "GW", "XXX XXXX", "Guinea-Bissau"])
    t.add(["592", "GY", "", "Guyana"])
    t.add(["852", "HK", "X XXX XXXX", "Hong Kong"])
    t.add(["504", "HN", "XXXX XXXX", "Honduras"])
    t.add(["385", "HR", "XX XXX XXX", "Croatia"])
    t.add(["509", "HT", "XXXX XXXX", "Haiti"])
    t.add(["36", "HU", "XXX XXX XXX", "Hungary"])
    t.add(["62", "ID", "XXX XXXXXX", "Indonesia"])
    t.add(["353", "IE", "XX XXX XXXX", "Ireland"])
    t.add(["972", "IL", "XX XXX XXXX", "Israel"])
    t.add(["91", "IN", "XXXXX XXXXX", "India"])
    t.add(["246", "IO", "XXX XXXX", "Diego Garcia"])
    t.add(["964", "IQ", "XXX XXX XXXX", "Iraq"])
    t.add(["98", "IR", "XXX XXX XXXX", "Iran"])
    t.add(["354", "IS", "XXX XXXX", "Iceland"])
    t.add(["39", "IT", "XXX XXX XXXX", "Italy"])
    t.add(["1876", "JM", "XXX XXXX", "Jamaica"])
    t.add(["962", "JO", "X XXXX XXXX", "Jordan"])
    t.add(["81", "JP", "XX XXXX XXXX", "Japan"])
    t.add(["254", "KE", "XXX XXX XXX", "Kenya"])
    t.add(["996", "KG", "XXX XXXXXX", "Kyrgyzstan"])
    t.add(["855", "KH", "XX XXX XXX", "Cambodia"])
    t.add(["686", "KI", "XXXX XXXX", "Kiribati"])
    t.add(["269", "KM", "XXX XXXX", "Comoros"])
    t.add(["1869", "KN", "XXX XXXX", "Saint Kitts & Nevis"])
    t.add(["850", "KP", "", "North Korea"])
    t.add(["82", "KR", "XX XXXX XXX", "South Korea"])
    t.add(["965", "KW", "XXXX XXXX", "Kuwait"])
    t.add(["1345", "KY", "XXX XXXX", "Cayman Islands"])
    t.add(["7", "RU", "XXX XXX XXXX", "Russian Federation"])
    t.add(["7", "KZ", "XXX XXX XX XX", "Kazakhstan"])
    t.add(["856", "LA", "XX XX XXX XXX", "Laos"])
    t.add(["961", "LB", "", "Lebanon"])
    t.add(["1758", "LC", "XXX XXXX", "Saint Lucia"])
    t.add(["423", "LI", "XXX XXXX", "Liechtenstein"])
    t.add(["94", "LK", "XX XXX XXXX", "Sri Lanka"])
    t.add(["231", "LR", "XX XXX XXXX", "Liberia"])
    t.add(["266", "LS", "XX XXX XXX", "Lesotho"])
    t.add(["370", "LT", "XXX XXXXX", "Lithuania"])
    t.add(["352", "LU", "XXX XXX XXX", "Luxembourg"])
    t.add(["371", "LV", "XXX XXXXX", "Latvia"])
    t.add(["218", "LY", "XX XXX XXXX", "Libya"])
    t.add(["212", "MA", "XX XXX XXXX", "Morocco"])
    t.add(["377", "MC", "XXXX XXXX", "Monaco"])
    t.add(["373", "MD", "XX XXX XXX", "Moldova"])
    t.add(["382", "ME", "", "Montenegro"])
    t.add(["261", "MG", "XX XX XXX XX", "Madagascar"])
    t.add(["692", "MH", "", "Marshall Islands"])
    t.add(["389", "MK", "XX XXXXXX", "North Macedonia"])
    t.add(["223", "ML", "XXXX XXXX", "Mali"])
    t.add(["95", "MM", "", "Myanmar"])
    t.add(["976", "MN", "XX XX XXXX", "Mongolia"])
    t.add(["853", "MO", "XXXX XXXX", "Macau"])
    t.add(["1670", "MP", "XXX XXXX", "Northern Mariana Islands"])
    t.add(["596", "MQ", "", "Martinique"])
    t.add(["222", "MR", "XXXX XXXX", "Mauritania"])
    t.add(["1664", "MS", "XXX XXXX", "Montserrat"])
    t.add(["356", "MT", "XX XX XX XX", "Malta"])
    t.add(["230", "MU", "XXXX XXXX", "Mauritius"])
    t.add(["960", "MV", "XXX XXXX", "Maldives"])
    t.add(["265", "MW", "XX XXX XXXX", "Malawi"])
    t.add(["52", "MX", "", "Mexico"])
    t.add(["60", "MY", "", "Malaysia"])
    t.add(["258", "MZ", "XX XXX XXXX", "Mozambique"])
    t.add(["264", "NA", "XX XXX XXXX", "Namibia"])
    t.add(["687", "NC", "", "New Caledonia"])
    t.add(["227", "NE", "XX XX XX XX", "Niger"])
    t.add(["672", "NF", "", "Norfolk Island"])
    t.add(["234", "NG", "XX XXXX XXXX", "Nigeria"])
    t.add(["505", "NI", "XXXX XXXX", "Nicaragua"])
    t.add(["31", "NL", "X XX XX XX XX", "Netherlands"])
    t.add(["47", "NO", "XXX XX XXX", "Norway"])
    t.add(["977", "NP", "XX XXXX XXXX", "Nepal"])
    t.add(["674", "NR", "", "Nauru"])
    t.add(["683", "NU", "", "Niue"])
    t.add(["64", "NZ", "XXXX XXXX", "New Zealand"])
    t.add(["968", "OM", "XXXX XXXX", "Oman"])
    t.add(["507", "PA", "XXXX XXXX", "Panama"])
    t.add(["51", "PE", "XXX XXX XXX", "Peru"])
    t.add(["689", "PF", "", "French Polynesia"])
    t.add(["675", "PG", "", "Papua New Guinea"])
    t.add(["63", "PH", "XXX XXX XXXX", "Philippines"])
    t.add(["92", "PK", "XXX XXX XXXX", "Pakistan"])
    t.add(["48", "PL", "XXX XXX XXX", "Poland"])
    t.add(["508", "PM", "", "Saint Pierre & Miquelon"])
    t.add(["1787", "PR", "XXX XXXX", "Puerto Rico"])
    t.add(["1939", "PR", "XXX XXXX", "Puerto Rico"])
    t.add(["970", "PS", "XXX XX XXXX", "Palestine"])
    t.add(["351", "PT", "XXX XXX XXX", "Portugal"])
    t.add(["680", "PW", "", "Palau"])
    t.add(["595", "PY", "XXX XXX XXX", "Paraguay"])
    t.add(["974", "QA", "XX XXX XXX", "Qatar"])
    t.add(["262", "RE", "XXX XXX XXX", "Réunion"])
    t.add(["40", "RO", "XXX XXX XXX", "Romania"])
    t.add(["381", "RS", "XX XXX XXX", "Serbia"])
    t.add(["250", "RW", "XXX XXX XXX", "Rwanda"])
    t.add(["966", "SA", "XX XXX XXXX", "Saudi Arabia"])
    t.add(["677", "SB", "", "Solomon Islands"])
    t.add(["248", "SC", "X XX XX XX", "Seychelles"])
    t.add(["249", "SD", "XX XXX XXXX", "Sudan"])
    t.add(["46", "SE", "XX XXX XXXX", "Sweden"])
    t.add(["65", "SG", "XXXX XXXX", "Singapore"])
    t.add(["247", "SH", "", "Saint Helena"])
    t.add(["290", "SH", "XX XXX", "Saint Helena"])
    t.add(["386", "SI", "XX XXX XXX", "Slovenia"])
    t.add(["421", "SK", "XXX XXX XXX", "Slovakia"])
    t.add(["232", "SL", "XX XXX XXX", "Sierra Leone"])
    t.add(["378", "SM", "", "San Marino"])
    t.add(["221", "SN", "XX XXX XXXX", "Senegal"])
    t.add(["252", "SO", "XX XXX XXX", "Somalia"])
    t.add(["597", "SR", "XXX XXXX", "Suriname"])
    t.add(["211", "SS", "XX XXX XXXX", "South Sudan"])
    t.add(["239", "ST", "XX XXXXX", "São Tomé & Príncipe"])
    t.add(["503", "SV", "XXXX XXXX", "El Salvador"])
    t.add(["1721", "SX", "XXX XXXX", "Sint Maarten"])
    t.add(["963", "SY", "XXX XXX XXX", "Syria"])
    t.add(["268", "SZ", "XXXX XXXX", "Eswatini"])
    t.add(["1649", "TC", "XXX XXXX", "Turks & Caicos Islands"])
    t.add(["235", "TD", "XX XX XX XX", "Chad"])
    t.add(["228", "TG", "XX XXX XXX", "Togo"])
    t.add(["66", "TH", "X XXXX XXXX", "Thailand"])
    t.add(["992", "TJ", "XX XXX XXXX", "Tajikistan"])
    t.add(["690", "TK", "", "Tokelau"])
    t.add(["670", "TL", "", "Timor-Leste"])
    t.add(["993", "TM", "XX XXXXXX", "Turkmenistan"])
    t.add(["216", "TN", "XX XXX XXX", "Tunisia"])
    t.add(["676", "TO", "", "Tonga"])
    t.add(["90", "TR", "XXX XXX XXXX", "Turkey"])
    t.add(["1868", "TT", "XXX XXXX", "Trinidad & Tobago"])
    t.add(["688", "TV", "", "Tuvalu"])
    t.add(["886", "TW", "XXX XXX XXX", "Taiwan"])
    t.add(["255", "TZ", "XX XXX XXXX", "Tanzania"])
    t.add(["380", "UA", "XX XXX XX XX", "Ukraine"])
    t.add(["256", "UG", "XX XXX XXXX", "Uganda"])
    t.add(["598", "UY", "X XXX XXXX", "Uruguay"])
    t.add(["998", "UZ", "XX XXX XX XX", "Uzbekistan"])
    t.add(["1784", "VC", "XXX XXXX", "Saint Vincent & the Grenadines"])
    t.add(["58", "VE", "XXX XXX XXXX", "Venezuela"])
    t.add(["1284", "VG", "XXX XXXX", "British Virgin Islands"])
    t.add(["1340", "VI", "XXX XXXX", "US Virgin Islands"])
    t.add(["84", "VN", "", "Vietnam"])
    t.add(["678", "VU", "", "Vanuatu"])
    t.add(["681", "WF", "", "Wallis & Futuna"])
    t.add(["685", "WS", "", "Samoa"])
    t.add(["383", "XK", "XXXX XXXX", "Kosovo"])
    t.add(["967", "YE", "XXX XXX XXX", "Yemen"])
    t.add(["27", "ZA", "XX XXX XXXX", "South Africa"])
    t.add(["260", "ZM", "XX XXX XXXX", "Zambia"])
    t.add(["263", "ZW", "XX XXX XXXX", "Zimbabwe"])
    t.add(["888", "FT", "XXXX XXXX", "Fragment"])
    return t
}

/**
 * 按 ISO-2 代码计算国旗 emoji。
 *
 * 逐字对照源侧 submodules/CountrySelectionUI/Sources/CountryList.swift:5
 * emojiFlagForISOCountryCode（含其对 submodules/TelegramStringFormatting/Sources/
 * Geo.swift:48 flagEmoji 的调用）：非 2 字符输入返回空串；FT/XG/XV/TS 四个特例
 * 分别返回海盗旗/卫星/地球/白旗；YL 返回空串；其余按每个大写字母的 Unicode 码点
 * + (0x1F1E6 - 'A' = 127397) 换算出对应 regional indicator symbol，两个依次拼接
 * 得到国旗 emoji（如 "US" -> 🇺 + 🇸 = 🇺🇸）。
 * 本表实际只会传入 phoneCountriesTable() 里出现过的 ISO2（含 FT），XG/XV/TS/YL
 * 分支为源侧同函数原样保留，不因本表未用到而删除（忠实源实现）。
 */
public func getCountryFlagByISO2(iso2: String): String {
    if (iso2.size != 2) {
        return ""
    }
    if (iso2 == "FT") {
        return "🏴‍☠️"
    } else if (iso2 == "XG") {
        return "🛰️"
    } else if (iso2 == "XV") {
        return "🌍"
    } else if (iso2 == "TS") {
        return "🏳️"
    }
    if (iso2 == "YL") {
        return ""
    }
    let upper = iso2.toAsciiUpper()
    let base: UInt32 = 127397
    let sb = StringBuilder()
    for (r in upper.toRuneArray()) {
        sb.append(Rune(base + UInt32(r)))
    }
    return sb.toString()
}

/**
 * 完整拨号代码表（236 行 / 233 个拨号代码，逐行对应源侧 PhoneCountries.txt）。
 * 每项为 [国家名, 拨号代码(含 "+"), 国旗 emoji, ISO-2 代码] —— 字段顺序与原实现
 * 保持一致，供 CountrySelectionPage / PhoneInputComponent / SinglePhoneInputComponent /
 * ContactListPage / AuthViewModel 等既有消费方零改动继续使用。国旗由
 * getCountryFlagByISO2 现算，不再硬编码存表。
 *
 * 与源侧 AuthorizationSequenceCountrySelectionControllerNode.swift:237-251 一致：
 * 源侧在按文件序读入 countryNamesAndCodes 后，显式 `.sorted(by: { lhs, rhs in
 * lhs.0.1 < rhs.0.1 })`（按显示名排序）才用于分节展示；phoneCountriesTable() 的
 * 原始顺序是 ISO2 序（仅 US/CA、RU/KZ 两处为凑后写覆盖而调整），并不等于名称序，
 * 若不重排，本文件既有的 buildCountrySections（按 name 首字母、检测"换字母"即开
 * 新分节，不做整体排序）会在原文件序下产生同一字母的多个不连续分节。因此这里对
 * 输出显式按 name（索引 0）稳定排序，复现源侧同一步骤，而不是保持 phoneCountries
 * Table() 的文件序——两者用途不同：查表（lookupCountryIdByNumber 等）依赖文件序
 * 的后写覆盖语义，展示列表依赖名称序的分节语义，源侧同样是两份不同顺序的视图。
 */
public func getCountryList(): ArrayList<Array<String>> {
    let list = ArrayList<Array<String>>()
    for (row in phoneCountriesTable()) {
        let code = row[0]
        let iso2 = row[1]
        let name = row[3]
        list.add([name, "+${code}", getCountryFlagByISO2(iso2), iso2])
    }
    sort<Array<String>, String>(list, key: {row: Array<String> => row[0]}, stable: true)
    return list
}

/**
 * 把字符串按 ASCII 字母数字连续游程切分为 token 数组，标点/空白均视为分隔符
 * （对应源侧 AuthorizationSequenceCountrySelectionControllerNode.swift 的
 * CFStringTokenizer word-unit 切分近似）。国家名/ISO2/拨号代码绝大多数为纯 ASCII
 * （少数含重音字符的名称如 Côte d'Ivoire / Réunion / São Tomé & Príncipe /
 * Curaçao 见下方已知限制），diacritic-insensitive fold 对本表其余部分无意义，
 * 故省略。
 */
private func alnumTokens(s: String): ArrayList<String> {
    let tokens = ArrayList<String>()
    var current = StringBuilder()
    for (r in s.toRuneArray()) {
        let code = Int64(UInt32(r))
        let isDigit = code >= 48 && code <= 57
        let isLower = code >= 97 && code <= 122
        let isUpper = code >= 65 && code <= 90
        if (isDigit || isLower || isUpper) {
            current.append(r)
        } else if (current.size > 0) {
            tokens.add(current.toString())
            current = StringBuilder()
        }
    }
    if (current.size > 0) {
        tokens.add(current.toString())
    }
    return tokens
}

/**
 * 源侧 abbrOne/abbrTwo 的仓颉对应：国家名按空格分词，取每个词首字母拼接，
 * 再去掉 "&"（如 "United Arab Emirates" -> "UAE"，对应 C2/C4 缩写命中）。
 * 目标国家表只有单一 name 字段（不像源侧区分 englishName/localizedName），
 * 只算一份即等价覆盖源侧两个同源缩写维度。
 */
private func abbreviateName(name: String): String {
    let words = name.split(" ")
    let sb = StringBuilder()
    for (w in words) {
        if (w.size > 0) {
            sb.append(w.toRuneArray()[0])
        }
    }
    return sb.toString().replace("&", "")
}

/**
 * queryTokens 的每个 token 都必须是 tokens 中某个 token 的前缀
 * （对应源侧 matchStringTokens：单 token / 多 token 走同一逐一验证语义，
 * 二者数学等价，故不再像源侧那样特判 count==1）
 */
private func matchTokens(tokens: ArrayList<String>, queryTokens: ArrayList<String>): Bool {
    if (queryTokens.size == 0) {
        return false
    }
    for (qt in queryTokens) {
        var found = false
        for (t in tokens) {
            if (t.startsWith(qt)) {
                found = true
                break
            }
        }
        if (!found) {
            return false
        }
    }
    return true
}

/**
 * 按名称、ISO2、拨号代码或首字母缩写搜索国家（token 前缀匹配）
 * 返回匹配的索引数组
 *
 * C2/C4 修复：原实现对 name/code/iso2 各做一次任意位置子串 contains 匹配，
 * 与源侧语义不等价——"apan" 会因 "japan".contains("apan") 误命中 Japan（假阳性），
 * 且无缩写维度导致 "UAE" 搜不到 United Arab Emirates（假阴性）。改为复刻源侧
 * searchCountries(items:query:)：拼接 "name iso2 abbr dialDigits" 后按词切 token，
 * 要求查询的每个 token 都是某个候选 token 的前缀。
 */
public func searchCountries(query: String): Array<Int64> {
    let countries = getCountryList()
    let result = ArrayList<Int64>()
    // HI-AUTH-0006: 输入法/焦点事件可能在 TextInput 里留下首尾空白（真机复现：
    // 聚焦搜索框首个 onChange 即带前导空格 " Japan"），若不 trim，token 化后前导
    // 空白会产生位置错乱。先 trim 再小写化，从根上防御空白噪声。
    let q = query.trim().toAsciiLower()
    if (q.size == 0) {
        for (i in 0..Int64(countries.size)) {
            result.add(i)
        }
        return Array<Int64>(result.size, { j: Int64 => result[j] })
    }
    let queryTokens = alnumTokens(q)
    for (i in 0..Int64(countries.size)) {
        let name = countries[i][0]
        let dial = countries[i][1]
        let iso2 = countries[i][3]
        let digits = if (dial.size > 0) { dial[1..dial.size] } else { dial }
        let abbr = abbreviateName(name)
        let searchString = "${name} ${iso2} ${abbr} ${digits}".toAsciiLower()
        let tokens = alnumTokens(searchString)
        if (matchTokens(tokens, queryTokens)) {
            result.add(i)
        }
    }
    return Array<Int64>(result.size, { j: Int64 => result[j] })
}

/**
 * 验证拨号代码是否在已知国家列表中
 */
public func isValidCountryCode(dialCode: String): Bool {
    let countries = getCountryList()
    for (i in 0..countries.size) {
        if (countries[i][1] == dialCode) {
            return true
        }
    }
    return false
}

/**
 * 根据拨号代码查找国家名。
 *
 * Rework round1 修复（Reviewer rejected M1 round0）：round0 曾误对 getCountryList()
 * （按显示名 stable 排序后的列表）取"最后一次命中"，排序会把 Canada 排到 United
 * States 之前、Kazakhstan 排到 Russian Federation 之前，导致对已排序列表取最后
 * 命中实际复算结果与本函数应复现的源侧语义相反（"+1" 误得 United States 而非
 * Canada，"+7" 误得 Russian Federation 而非 Kazakhstan）。getCountryList() 的
 * 排序只服务于 buildCountrySections 的展示分节这一条数据路径，不能被任何按
 * dialCode 反查国家/国旗的函数复用。
 *
 * 改为直接对 phoneCountriesTable()（文件序，PhoneCountries.txt 原序）建立
 * dialCode -> row 的 HashMap 后查表——同一 key 后写入的 row 自然覆盖先写入的，
 * 等价于"逐行扫描到底、以最后一次命中为准"，与 lookupCountryIdByNumber 已经
 * 采用的正确写法一致，也与源侧 countryCodesByPrefix 的"后写覆盖"语义一致
 * （"+1" 以 CA 结尾覆盖，"+7" 以 KZ 结尾覆盖，"+599" 以 CW 结尾覆盖）。
 */
public func getCountryNameByCode(dialCode: String): String {
    let byCode = HashMap<String, Array<String>>()
    for (row in phoneCountriesTable()) {
        byCode["+${row[0]}"] = row
    }
    match (byCode.get(dialCode)) {
        case Some(row) => return row[3]
        case None => return ""
    }
}

/**
 * 根据拨号代码查找国旗 emoji（同 getCountryNameByCode 的"文件序后写覆盖"取舍与
 * rework round1 修复说明，见上方注释）。
 */
public func getEmojiByCode(dialCode: String): String {
    let byCode = HashMap<String, Array<String>>()
    for (row in phoneCountriesTable()) {
        byCode["+${row[0]}"] = row
    }
    match (byCode.get(dialCode)) {
        case Some(row) => return getCountryFlagByISO2(row[1])
        case None => return ""
    }
}

/**
 * P2-012: 根据 ISO-2 国家代码查找拨号代码和国家名
 * iso2 如 "CN", "US", "GB"
 * 返回 (dialCode, countryName)，未找到则返回 ("", "")
 */
public func getCountryByIso2(iso2: String): (String, String) {
    let upper = iso2.toAsciiUpper()
    let countries = getCountryList()
    for (i in 0..countries.size) {
        if (countries[i][3] == upper) {
            return (countries[i][1], countries[i][0])
        }
    }
    return ("", "")
}

/**
 * P2-011: 根据 BCP47 language tag 中的地区部分推断拨号代码
 * 如 "zh-CN" → "+86"/"China", "en-US" → "+1"/"United States"
 * 返回 (dialCode, countryName)，无法确定时返回 ("", "")
 */
public func getCountryByLocaleTag(langTag: String): (String, String) {
    // BCP47 语言标签：zh-CN, en-US, fr-FR, pt-BR 等
    // 提取地区部分：语言标签以 "-" 分割，取最后一个 2 字母大写段作为 ISO-2
    let parts = langTag.split("-")
    if (parts.size >= 2) {
        let region = parts[parts.size - 1]
        if (region.size == 2) {
            return getCountryByIso2(region)
        }
    }
    // 也尝试整体作为 ISO-2 或者只有语言代码时的推断
    if (langTag.size == 2) {
        // 仅语言代码，尝试常见映射
        return getCountryByLanguageCode(langTag)
    }
    return ("", "")
}

/**
 * 仅凭语言代码推断国家（最后备选）
 * 如 "zh" → CN, "ja" → JP, "ko" → KR
 */
private func getCountryByLanguageCode(lang: String): (String, String) {
    let l = lang.toAsciiLower()
    match (l) {
        case "zh" => return getCountryByIso2("CN")
        case "ja" => return getCountryByIso2("JP")
        case "ko" => return getCountryByIso2("KR")
        case "ru" => return getCountryByIso2("RU")
        case "ar" => return getCountryByIso2("SA")
        case "hi" => return getCountryByIso2("IN")
        case "pt" => return getCountryByIso2("PT")
        case "de" => return getCountryByIso2("DE")
        case "fr" => return getCountryByIso2("FR")
        case "es" => return getCountryByIso2("ES")
        case "it" => return getCountryByIso2("IT")
        case "nl" => return getCountryByIso2("NL")
        case "pl" => return getCountryByIso2("PL")
        case "tr" => return getCountryByIso2("TR")
        case "vi" => return getCountryByIso2("VN")
        case "th" => return getCountryByIso2("TH")
        case "uk" => return getCountryByIso2("UA")
        case "fa" => return getCountryByIso2("IR")
        case _ => return ("", "")
    }
}

/**
 * 国家分区（用于 A-Z 分组显示）
 */
public class CountrySection {
    public var letter: String = ""
    public var indices: ArrayList<Int64> = ArrayList<Int64>()

    public init() {}

    public init(letter: String, indices: ArrayList<Int64>) {
        this.letter = letter
        this.indices = indices
    }
}

/**
 * 国家列表显示项（分区头或国家行）
 */
public class CountryDisplayItem <: ToString {
    public var isSection: Bool = false
    public var sectionLetter: String = ""
    public var countryIndex: Int64 = -1
    // N-3-② insetGrouped 卡片分组（diag-suite_auth_login-TC-0008 rework round2）：
    // 源侧两张 UITableView 在 glass 形态下都是 .insetGrouped——每个字母组（或整个
    // 搜索结果表）渲染成一张白色圆角卡片。country 行本身不知道自己在卡片内的
    // 位置，由 applyCardGrouping() 在扁平化之后按前后邻居回填，countryRow() 据此
    // 只圆首/尾行对应角，卡片中间行不设圆角，视觉上无缝拼成一张卡。
    public var isFirstInCard: Bool = false
    public var isLastInCard: Bool = false

    public static func section(letter: String): CountryDisplayItem {
        let item = CountryDisplayItem()
        item.isSection = true
        item.sectionLetter = letter
        return item
    }

    public static func country(idx: Int64): CountryDisplayItem {
        let item = CountryDisplayItem()
        item.isSection = false
        item.countryIndex = idx
        return item
    }

    public func toString(): String {
        if (this.isSection) {
            return "section_${this.sectionLetter}"
        }
        return "country_${this.countryIndex}"
    }
}

/**
 * N-3-② insetGrouped 卡片分组回填：country 行前一项是 section 头（或自身是列表
 * 首项）即为卡片首行；后一项是 section 头（或自身是列表末项）即为卡片末行。
 * 对没有任何 section 头的搜索结果扁平列表（flattenCountryIndices）同样适用——
 * 整个结果集自然回填成"首项 isFirstInCard、末项 isLastInCard"的单张卡片，
 * 与源侧 searchTableView 同为 .insetGrouped（无节头，仍是一张卡）语义一致。
 */
func applyCardGrouping(items: ArrayList<CountryDisplayItem>): Unit {
    var i: Int64 = 0
    let total = Int64(items.size)
    while (i < total) {
        let item = items[i]
        if (!item.isSection) {
            item.isFirstInCard = (i == 0) || items[i - 1].isSection
            item.isLastInCard = (i == total - 1) || items[i + 1].isSection
        }
        i = i + 1
    }
}

/**
 * 将国家索引按首字母分组
 */
public func buildCountrySections(filteredIndices: Array<Int64>): ArrayList<CountrySection> {
    let countries = getCountryList()
    let sections = ArrayList<CountrySection>()
    var currentLetter: String = ""
    var currentIndices = ArrayList<Int64>()

    for (idx in filteredIndices) {
        let name = countries[idx][0]
        let letter = if (name.size > 0) {
            let runes = name.toRuneArray()
            let code = Int64(UInt32(runes[0]))
            if (code >= 65 && code <= 90) { name[0..1] }
            else if (code >= 97 && code <= 122) { name[0..1].toAsciiUpper() }
            else if (code >= 48 && code <= 57) { "#" }
            else { "#" }
        } else { "#" }

        if (letter != currentLetter) {
            if (currentIndices.size > 0) {
                sections.add(CountrySection(currentLetter, currentIndices))
            }
            currentLetter = letter
            currentIndices = ArrayList<Int64>()
        }
        currentIndices.add(idx)
    }
    if (currentIndices.size > 0) {
        sections.add(CountrySection(currentLetter, currentIndices))
    }
    return sections
}

/**
 * 扁平化分区为显示项列表
 */
public func flattenCountrySections(sections: ArrayList<CountrySection>): ArrayList<CountryDisplayItem> {
    let result = ArrayList<CountryDisplayItem>()
    for (sec in sections) {
        result.add(CountryDisplayItem.section(sec.letter))
        for (idx in sec.indices) {
            result.add(CountryDisplayItem.country(idx))
        }
    }
    applyCardGrouping(result)
    return result
}

/**
 * C5 修复：搜索结果态平铺显示项，不生成分区头。对应源侧 searchTableView 单一
 * 结果表——titleForHeaderInSection/sectionIndexTitles 对搜索表返回 nil，因此
 * 结果态既无节头也无字母索引（AlphabetIndexer 的隐藏由调用方 build() 负责）。
 */
public func flattenCountryIndices(indices: Array<Int64>): ArrayList<CountryDisplayItem> {
    let result = ArrayList<CountryDisplayItem>()
    for (idx in indices) {
        result.add(CountryDisplayItem.country(idx))
    }
    applyCardGrouping(result)
    return result
}

/**
 * 逐字对照源侧 AuthorizationSequenceCountrySelectionController.swift:189-199
 * removePlus(_:)：剔除字符串中所有 "+" 字符（不仅限于首位）。
 */
private func stripPlusChars(text: String): String {
    let sb = StringBuilder()
    for (r in text.toRuneArray()) {
        if (UInt32(r) != UInt32(r'+')) {
            sb.append(r)
        }
    }
    return sb.toString()
}

/**
 * 逐字对照源侧 AuthorizationSequenceCountrySelectionController.swift:229-268
 * lookupCountryIdByNumber(_:preferredCountries:)：从最长前缀往短逐位截取查字典，
 * 命中即返回。
 *
 * preferredCountries 化简说明：本屏调用点固定传空表，源算法在 preferredCountries
 * 为空时，`number.count == 1` 首位命中分支不成立（字典为空），而主循环里任何
 * 后续命中的 code 长度必然严格短于首次命中（因为前缀长度按 i 递增逐位缩短），
 * 触发源码 :240-241 的 `result.1.code.count > country.1.code.count` ⇒ break 而
 * 不追加——数学上等价于"最长前缀命中即停"，结果集合恒为 0 或 1 个元素。故本
 * 函数省略 preferredCountries 参数与其消歧分支，未改变 preferredCountries 为空
 * 时的可观察行为，也未新增任何自定义近似逻辑。
 *
 * 订正（diag-suite_auth_login-TC-0006 round2 D1 结论）：本段此前称 preferredCountries
 * 消歧「交由 M4 宿主页的 preferredCountryIdForCode 累积逻辑承接」，该说法不再
 * 成立——不是因为 M4 迟迟未落地，而是事后核实这本就不是 preferredCountries 该去
 * 的地方：源侧的身份消歧走的是另一条独立机制（`PhoneInputNode.countryNameForCode`
 * 身份随行 + `countryCodeAndIdToName` 按 (code, ISO2) 二元键精确取名，见
 * CountryList.swift:105-121），与本函数依附的 `countryCodesByPrefix`（:62，
 * "后写覆盖"）是源侧两套并列机制，不是同一函数内的可选分支。本文件下方已补齐
 * 对应的 `lookupCanonicalCountryByCode`（对位 CountryList.swift:95-102 的
 * `countryCodeToIdAndName`，"先写胜"，服务"只知道拨号代码、无身份"场景）与
 * `lookupCountryNameByCodeAndIso2`（对位 :112-119 的 `countryCodeAndIdToName`，
 * 按 (拨号代码, ISO2) 精确取名，服务已知身份场景）两个函数——消歧真正的落点
 * 在那两个函数，不在本函数、也不在某个未落地的宿主页。
 *
 * 查表字典遵循源侧 countryCodesByPrefix 的"后写覆盖"语义：phoneCountriesTable()
 * 中同一拨号代码的多行按文件原序，后出现的行覆盖先出现的（如 "1" 先 US 后 CA，
 * 最终以 CA 为准 —— 对应源侧 :62 `countriesByPrefix["\(code.code)"] = (country, code)`）。
 * 该"后写覆盖"表与下方新增的"先写胜"表刻意并存，各自服务源侧对应的调用点，
 * 互不改动、互不替代（见下方新增函数注释的对照说明）。
 *
 * 返回 (code, iso2, pattern, name)；查不到返回 None（不得杜撰默认值，M1 边界约束）。
 */
public func lookupCountryIdByNumber(digits: String): ?(String, String, String, String) {
    let number = stripPlusChars(digits)
    if (number.size == 0) {
        return None
    }
    let byCode = HashMap<String, Array<String>>()
    for (row in phoneCountriesTable()) {
        byCode[row[0]] = row
    }
    var i: Int64 = 0
    let total = number.size
    while (i < total) {
        let prefixLen = total - i
        let prefix = number[0..prefixLen]
        match (byCode.get(prefix)) {
            case Some(row) => return (row[0], row[1], row[2], row[3])
            case None => ()
        }
        i = i + 1
    }
    return None
}

/**
 * 逐字对照源侧 :277-295 lookupPatternByNumber(_:preferredCountries:)。
 *
 * 化简说明：源函数在找到国家后，用该国 pattern 去掉空格/"X" 拼出 cleanPrefix 重新
 * 按最长前缀匹配一次；本表 pattern 全部由 "X" 与空格组成（机械转录自
 * PhoneCountries.txt 第 3 列），去除两者后恒为空串，故 cleanPrefix 恒等于该国
 * dialCode 本身——而该 dialCode 正是 lookupCountryIdByNumber 已经匹配到的最长
 * 前缀，因此源函数的二次匹配必然命中同一 pattern。机械等价于：country 命中且其
 * pattern 非空 ⇒ 直接返回该 pattern。
 *
 * 查不到国家、或该国 pattern 为空（源侧对应 mask == nil，即该国当前无 mask）
 * 均返回 None，不得杜撰默认 pattern（M1 边界约束）。
 */
public func lookupPatternByNumber(digits: String): ?String {
    match (lookupCountryIdByNumber(digits)) {
        case Some((_, _, pattern, _)) =>
            if (pattern.size > 0) {
                return Some(pattern)
            }
            return None
        case None => return None
    }
}

/**
 * 逐字对照源侧 submodules/CountrySelectionUI/Sources/CountryList.swift:95-102
 * `countryCodeToIdAndName`：
 *
 *   public let countryCodeToIdAndName: [Int: (String, String)] = {
 *       var dict: [Int: (String, String)] = [:]
 *       for (code, id, name) in phoneCountriesInfo {
 *           if dict[code] == nil {
 *               dict[code] = (id, name)
 *           }
 *       }
 *       return dict
 *   }()
 *
 * "先写胜"语义——只在键不存在时写入，因此同一拨号代码的多行里，文件序中最先
 * 出现的那行胜出。与 lookupCountryIdByNumber / getCountryNameByCode / getEmojiByCode
 * （源侧 countryCodesByPrefix 的"后写覆盖"语义，:62）刻意并存、互不改动——
 * 源侧对"同一拨号代码多国共用"本就用两套相反定序服务不同调用点：
 *
 *   - 本函数（先写胜）：手机号屏"只知道拨号代码、要显示一个规范国家"时用（源侧
 *     `AuthorizationSequencePhoneEntryControllerNode` 的 `countryCodeUpdated`
 *     闭包，CountryList.swift:95-102 消费方）。phoneCountriesTable()
 *     （PhoneCountries.txt 原序）里 US（第 70 行/源文件:34）先于 CA（第 71 行/
 *     源文件:35）⇒ "1" 恒得 US；RU（第 152 行/源文件:116）先于 KZ（第 153 行/
 *     源文件:117）⇒ "7" 恒得 RU；BQ（第 63 行/源文件:27）先于 CW（第 85 行/
 *     源文件:49）⇒ "599" 恒得 BQ。
 *   - lookupCountryIdByNumber 等（后写覆盖）：号码前缀识别 / mask 查询用，
 *     "1" 恒得 CA，"7" 恒得 KZ，"599" 恒得 CW。
 *
 * dialDigits 为不含 "+" 的纯数字拨号代码（如 "1"、"7"、"599"）。
 * 返回 (iso2, name)；查不到返回 None（不得杜撰默认值，M1 边界约束延续）。
 */
public func lookupCanonicalCountryByCode(dialDigits: String): ?(String, String) {
    let byCode = HashMap<String, Array<String>>()
    for (row in phoneCountriesTable()) {
        byCode.addIfAbsent(row[0], row)
    }
    match (byCode.get(dialDigits)) {
        case Some(row) => return (row[1], row[3])
        case None => return None
    }
}

/**
 * 逐字对照源侧 CountryList.swift:105-121 `CountryCodeAndId` / `countryCodeAndIdToName`：
 *
 *   public struct CountryCodeAndId: Hashable {
 *       let code: Int
 *       let id: String
 *   }
 *   public let countryCodeAndIdToName: [CountryCodeAndId: String] = {
 *       var dict: [CountryCodeAndId: String] = [:]
 *       for (code, id, name) in phoneCountriesInfo {
 *           dict[CountryCodeAndId(code: code, id: id)] = name
 *       }
 *       return dict
 *   }()
 *
 * 按 (拨号代码, ISO2) 组合键精确取国家名——服务源侧"国家身份显式随行"场景（宿主
 * 已知具体国家，如用户在国家选择屏手选过、或宿主回填过 identity），纯精确匹配、
 * 不做任何定序消歧（同一 (code, id) 组合在源表中只会对应同一个 name）。
 *
 * dialDigits 为不含 "+" 的纯数字拨号代码，iso2 为两位大写 ISO-2 代码。
 * 返回 name；查不到返回 None（不得杜撰默认值，M1 边界约束延续）。
 */
public func lookupCountryNameByCodeAndIso2(dialDigits: String, iso2: String): ?String {
    for (row in phoneCountriesTable()) {
        if (row[0] == dialDigits && row[1] == iso2) {
            return row[3]
        }
    }
    return None
}
