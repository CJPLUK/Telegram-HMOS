package ohos_app_cangjie_entry.core.theme

import std.random.Random

/**
 * ThemeNameGenerator — 对位
 * submodules/TelegramUI/Components/Settings/GenerateThemeName/Sources/GenerateThemeName.swift。
 *
 * diag-suite_settings_appearance-TC-0416.md §F3（该报告把这个文件划给 `shell_settings_wallpaper`，
 * 因为 `shell_settings_wallpaper.source_refs` 点名了 `generateThemeName`；本轮 Supervisor 派发时把
 * `core/theme/ThemeNameGenerator.cj` 直接加进了 `set_theme_editing` 的 allowlist——本 feature是
 * `generateThemeName` 目前唯一真实调用点（`pages/EditThemePage.cj` 的 Theme Name 预填值），
 * 由同一 Worker 一次实现调用方与被调用方，避免跨 feature 空接线窗口。若后续
 * `shell_settings_wallpaper` 也需要它（源侧第二调用点 `ThemeAccentColorController.swift:264`
 * 对应的取色器屏目标侧尚不存在，见该报告 §F3 末段），直接 import 本文件，不得另起第二份实现。
 *
 * 三张词表逐项照抄源码（一个色值、一个词条都不改，不裁剪）：
 *   - `THEME_NAME_COLOR_HEX` / `THEME_NAME_COLOR_NAME`：99 组颜色→名字（源码 `:4-104`
 *     的字面量个数，与该诊断报告估算的 "98 项" 不同——源文件实测精确计数是 99，本文件以
 *     源码为准，不是报告的口误数字）。两个数组按源码字面量出现顺序一一对应（同下标配对，
 *     不是排序结果），第 41 项（`0x0000ff`）与第 99 项（`0x54a5f8`）的名字都是 "Blue"——
 *     这是源码字典的真实内容（值可重复，键唯一），不是本文件的錄入错误。
 *   - `THEME_NAME_ADJECTIVES`：107 项（源码 `:106-214`）。
 *   - `THEME_NAME_SUBJECTIVES`：81 项（源码 `:216-298`）。
 */
let THEME_NAME_COLOR_HEX: Array<UInt32> = [
    0x8e0000, 0xdec196, 0x800b47, 0xff7f50, 0xdb5079, 0xdc143c, 0xe0b0ff, 0xffc0cb, 0xff0000, 0xff007f,
    0x80461b, 0xff2400, 0xf1f1f1, 0xff3399, 0xffbf00, 0xeb9373, 0xfbe7b2, 0xa1c50a, 0xb06500, 0xffd700,
    0xfde910, 0xffa500, 0xffe5b4, 0xff6b53, 0xe4d422, 0xf28500, 0xffc87c, 0xffff00, 0x384910, 0x83aa5d,
    0x50c878, 0xb5b35c, 0x00ff00, 0x00a86b, 0x29ab87, 0xbfff00, 0x0bda51, 0x98ff98, 0xaddfad, 0x315ba1,
    0x0000ff, 0x0047ab, 0x4f69c6, 0x017987, 0x71d9e2, 0x120a8f, 0x000080, 0x2f519e, 0x76d7ea, 0x008080,
    0x40e0d0, 0x9966cc, 0x4d0135, 0x614051, 0xc8a2c8, 0xb57edc, 0xccccff, 0x843179, 0x660099, 0xd8bfd8,
    0xda70d6, 0x240a40, 0x3f2109, 0x370202, 0x7b3f00, 0x301f1e, 0x706555, 0x796989, 0x4e0606, 0x782d19,
    0xc2b280, 0x882d17, 0x780109, 0xf0e68c, 0xb87333, 0xb94e48, 0xeed9c4, 0xfffdd0, 0xb9f2ff, 0xa98307,
    0xfffff0, 0xeae0c8, 0xeff2f3, 0xd1bea8, 0xffffff, 0x808080, 0x000000, 0xe8f1d4, 0x36454f, 0x0c0b1d,
    0xc0c0c0, 0xf5f5f5, 0x262335, 0x4fa83d, 0x80b3c4, 0xfebaad, 0xc54b8c, 0xa9c6c2, 0x54a5f8
]

let THEME_NAME_COLOR_NAME: Array<String> = [
    "Berry", "Brandy", "Cherry", "Coral", "Cranberry", "Crimson", "Mauve", "Pink", "Red", "Rose",
    "Russet", "Scarlet", "Seashell", "Strawberry", "Amber", "Apricot", "Banana", "Citrus", "Ginger", "Gold",
    "Lemon", "Orange", "Peach", "Persimmon", "Sunflower", "Tangerine", "Topaz", "Yellow", "Clover", "Cucumber",
    "Emerald", "Olive", "Green", "Jade", "Jungle", "Lime", "Malachite", "Mint", "Moss", "Azure",
    "Blue", "Cobalt", "Indigo", "Lagoon", "Aquamarine", "Ultramarine", "Navy", "Sapphire", "Sky", "Teal",
    "Turquoise", "Amethyst", "Blackberry", "Eggplant", "Lilac", "Lavender", "Periwinkle", "Plum", "Purple", "Thistle",
    "Orchid", "Violet", "Bronze", "Chocolate", "Cinnamon", "Cocoa", "Coffee", "Rum", "Mahogany", "Mocha",
    "Sand", "Sienna", "Maple", "Khaki", "Copper", "Chestnut", "Almond", "Cream", "Diamond", "Honey",
    "Ivory", "Pearl", "Porcelain", "Vanilla", "White", "Gray", "Black", "Chrome", "Charcoal", "Ebony",
    "Silver", "Smoke", "Steel", "Apple", "Glacier", "Melon", "Mulberry", "Opal", "Blue"
]

let THEME_NAME_ADJECTIVES: Array<String> = [
    "Ancient", "Antique", "Autumn", "Baby", "Barely", "Baroque", "Blazing", "Blushing", "Bohemian",
    "Bubbly", "Burning", "Buttered", "Classic", "Clear", "Cool", "Cosmic", "Cotton", "Cozy",
    "Crystal", "Dark", "Daring", "Darling", "Dawn", "Dazzling", "Deep", "Deepest", "Delicate",
    "Delightful", "Divine", "Double", "Downtown", "Dreamy", "Dusky", "Dusty", "Electric",
    "Enchanted", "Endless", "Evening", "Fantastic", "Flirty", "Forever", "Frigid", "Frosty",
    "Frozen", "Gentle", "Heavenly", "Hyper", "Icy", "Infinite", "Innocent", "Instant", "Luscious",
    "Lunar", "Lustrous", "Magic", "Majestic", "Mambo", "Midnight", "Millenium", "Morning",
    "Mystic", "Natural", "Neon", "Night", "Opaque", "Paradise", "Perfect", "Perky", "Polished",
    "Powerful", "Rich", "Royal", "Sheer", "Simply", "Sizzling", "Solar", "Sparkling", "Splendid",
    "Spicy", "Spring", "Stellar", "Sugared", "Summer", "Sunny", "Super", "Sweet", "Tender",
    "Tenacious", "Tidal", "Toasted", "Totally", "Tranquil", "Tropical", "True", "Twilight",
    "Twinkling", "Ultimate", "Ultra", "Velvety", "Vibrant", "Vintage", "Virtual", "Warm",
    "Warmest", "Whipped", "Wild", "Winsome"
]

let THEME_NAME_SUBJECTIVES: Array<String> = [
    "Ambrosia", "Attack", "Avalanche", "Blast", "Bliss", "Blossom", "Blush", "Burst", "Butter",
    "Candy", "Carnival", "Charm", "Chiffon", "Cloud", "Comet", "Delight", "Dream", "Dust",
    "Fantasy", "Flame", "Flash", "Fire", "Freeze", "Frost", "Glade", "Glaze", "Gleam", "Glimmer",
    "Glitter", "Glow", "Grande", "Haze", "Highlight", "Ice", "Illusion", "Intrigue", "Jewel",
    "Jubilee", "Kiss", "Lights", "Lollypop", "Love", "Luster", "Madness", "Matte", "Mirage",
    "Mist", "Moon", "Muse", "Myth", "Nectar", "Nova", "Parfait", "Passion", "Pop", "Rain",
    "Reflection", "Rhapsody", "Romance", "Satin", "Sensation", "Silk", "Shine", "Shadow",
    "Shimmer", "Sky", "Spice", "Star", "Sugar", "Sunrise", "Sunset", "Sun", "Twist", "Unbound",
    "Velvet", "Vibrant", "Waters", "Wine", "Wink", "Wonder", "Zone"
]

private let themeNameRandom: Random = Random()

/**
 * 对位 `UIColor.distance(to:)`（`UIKitUtils.swift:454-462`，redmean 色距公式）。入参是两个
 * 0xRRGGBB 分量拆出的 (r,g,b)，Int32 范围 0..255；返回值只用于比较大小，不是感知距离的物理单位。
 * 源码表达式 `((512 + rMean) * r * r) >> 8 + 4 * g * g + ((767 - rMean) * b * b) >> 8` 里
 * `>>` 优先级高于 `+`（Swift BitwiseShiftPrecedence > AdditionPrecedence），等价于
 * `(A >> 8) + B + (C >> 8)`；本函数直接显式加括号，不依赖仓颉的运算符优先级去复现 Swift 的隐式分组。
 */
private func colorDistance(r1: Int32, g1: Int32, b1: Int32, r2: Int32, g2: Int32, b2: Int32): Int32 {
    let rMean = (r1 + r2) / 2
    let dr = r1 - r2
    let dg = g1 - g2
    let db = b1 - b2
    let term1 = ((512 + rMean) * dr * dr) >> 8
    let term2 = 4 * dg * dg
    let term3 = ((767 - rMean) * db * db) >> 8
    return term1 + term2 + term3
}

private func redComponent(hex: UInt32): Int32 {
    Int32((hex >> 16) & 0xFF)
}

private func greenComponent(hex: UInt32): Int32 {
    Int32((hex >> 8) & 0xFF)
}

private func blueComponent(hex: UInt32): Int32 {
    Int32(hex & 0xFF)
}

/**
 * 对位 `generateThemeName(accentColor:)`（`GenerateThemeName.swift:300-321`）。
 * `accentColor` 是 0xRRGGBB（或带 alpha 的 0xAARRGGBB，本函数只读低 24 位，与源码
 * `UIColor.colorComponents` 只取 RGB、忽略 alpha 的行为一致）。
 *
 * 1) 遍历 99 项颜色表求最近色（`colorDistance` 最小者），色距公式与遍历顺序对表结果无影响——
 *    源码是 `[UInt32: String]` 字典，遍历顺序本就不确定，只有"取最小距离"这个结果是确定的。
 * 2) 50/50 分叉：`Random().nextInt32(2) == 0` 对位 `arc4random() % 2 == 0`，形态
 *    `"<adjective> <colorName>"`；否则 `"<colorName> <subjective>"`。
 * 3) 空表兜底：`THEME_NAME_COLOR_HEX` 非空（99 项常量），`nearest` 恒有值，故 `""` 分支
 *    在本工程语义上不可达，但仍照源码写出该分支（源码 `nearest` 是 Optional，本函数用
 *    `found: Bool` 镜像同一个"未找到"状态，保留该分支以便词表将来被清空时行为不突变）。
 */
public func generateThemeName(accentColor: UInt32): String {
    let ar = redComponent(accentColor)
    let ag = greenComponent(accentColor)
    let ab = blueComponent(accentColor)

    var nearestIndex: Int64 = -1
    var nearestDistance: Int32 = 0
    var found = false

    var i: Int64 = 0
    while (i < THEME_NAME_COLOR_HEX.size) {
        let candidate = THEME_NAME_COLOR_HEX[i]
        let dist = colorDistance(ar, ag, ab, redComponent(candidate), greenComponent(candidate), blueComponent(candidate))
        if (!found || dist < nearestDistance) {
            nearestDistance = dist
            nearestIndex = i
            found = true
        }
        i = i + 1
    }

    if (!found || nearestIndex < 0) {
        return ""
    }

    let colorName = THEME_NAME_COLOR_NAME[nearestIndex]
    if (themeNameRandom.nextInt32(2) == 0) {
        let idx = Int64(themeNameRandom.nextInt32(Int32(THEME_NAME_ADJECTIVES.size)))
        return "${THEME_NAME_ADJECTIVES[idx]} ${colorName}"
    } else {
        let idx = Int64(themeNameRandom.nextInt32(Int32(THEME_NAME_SUBJECTIVES.size)))
        return "${colorName} ${THEME_NAME_SUBJECTIVES[idx]}"
    }
}
