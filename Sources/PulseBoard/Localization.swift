import Combine
import Foundation

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    static let defaultsKey = "PulseBoard.appLanguage"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: L10n.text("language.system")
        case .simplifiedChinese: L10n.text("language.zh_hans")
        case .english: L10n.text("language.english")
        }
    }
}

@MainActor
final class LocalizationManager: ObservableObject {
    @Published var language: AppLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: AppLanguage.defaultsKey) }
    }

    init() {
        language = UserDefaults.standard.string(forKey: AppLanguage.defaultsKey)
            .flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    var locale: Locale { L10n.locale(for: language) }
}

enum L10n {
    private static var selectedLanguage: AppLanguage {
        UserDefaults.standard.string(forKey: AppLanguage.defaultsKey)
            .flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    static var locale: Locale {
        locale(for: selectedLanguage)
    }

    static func locale(for language: AppLanguage) -> Locale {
        switch language {
        case .system:
            Locale(identifier: Bundle.module.preferredLocalizations.first ?? Locale.current.identifier)
        case .simplifiedChinese, .english:
            Locale(identifier: language.rawValue)
        }
    }

    static func text(_ key: String) -> String {
        bundle(for: selectedLanguage).localizedString(forKey: key, value: key, table: nil)
    }

    static func text(_ key: String, language: String) -> String {
        localizedBundle(for: language)?.localizedString(forKey: key, value: key, table: nil) ?? key
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: locale, arguments: arguments)
    }

    private static func bundle(for language: AppLanguage) -> Bundle {
        switch language {
        case .system: Bundle.module
        case .simplifiedChinese, .english:
            localizedBundle(for: language.rawValue) ?? Bundle.module
        }
    }

    private static func localizedBundle(for language: String) -> Bundle? {
        guard let localization = Bundle.module.localizations.first(where: {
            $0.caseInsensitiveCompare(language) == .orderedSame
        }),
        let path = Bundle.module.path(forResource: localization, ofType: "lproj") else { return nil }
        return Bundle(path: path)
    }
}
