import SwiftUI

// MARK: - 应用语言
//
// 用 macOS 标准机制：把选择写进本应用的 AppleLanguages，
// 系统在下次启动时据此挑选 Localizable.strings，因此需要重启才生效。
enum AppLanguage: String, CaseIterable, Identifiable {
    case system = ""
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .system:            return "settings.language.system"
        case .english:           return "settings.language.english"
        case .simplifiedChinese: return "settings.language.chinese"
        }
    }

    /// 写入 / 清除 AppleLanguages
    func apply() {
        switch self {
        case .system:
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        case .english, .simplifiedChinese:
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
    }

    /// 当前生效的语言（用于恢复选择状态）
    static var current: AppLanguage {
        guard let code = Bundle.main.preferredLocalizations.first else { return .system }
        return AppLanguage(rawValue: code) ?? .system
    }
}
