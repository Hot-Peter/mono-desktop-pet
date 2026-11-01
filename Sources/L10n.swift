import Foundation

/// 界面语言：中文 / English
enum Lang: String {
    case zh, en
}

/// 极简本地化：只覆盖用户看到的几十条文案（气泡 + 菜单）。
///
/// 默认跟随系统首选语言（`zh*` → 中文，其余 → 英文），也可以在小人菜单里
/// 强制指定「中文 / English」，选择存进 UserDefaults，重启后仍然有效。
enum L10n {
    /// "system" | "zh" | "en"
    private static let key = "uiLanguage"

    static var mode: String {
        get { UserDefaults.standard.string(forKey: key) ?? "system" }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
            UserDefaults.standard.synchronize()
        }
    }

    static var lang: Lang {
        switch mode {
        case "zh": return .zh
        case "en": return .en
        default: return systemLang
        }
    }

    /// 系统首选语言列表里第一个能识别的（第一个通常是用户自己的语言）
    static var systemLang: Lang {
        for id in Locale.preferredLanguages {
            let low = id.lowercased()
            if low.hasPrefix("zh") { return .zh }
            if low.hasPrefix("en") { return .en }
        }
        return .en   // 其他语种一律英文（没有第三方翻译资源）
    }
}

/// 取当前语言的一条文案：T(中文, English)
func T(_ zh: String, _ en: String) -> String { L10n.lang == .zh ? zh : en }
