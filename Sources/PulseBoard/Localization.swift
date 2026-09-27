import Foundation

enum L10n {
    static var locale: Locale {
        Locale(identifier: Bundle.module.preferredLocalizations.first ?? "en")
    }

    static func text(_ key: String) -> String {
        Bundle.module.localizedString(forKey: key, value: key, table: nil)
    }

    static func text(_ key: String, language: String) -> String {
        guard let localization = Bundle.module.localizations.first(where: {
            $0.caseInsensitiveCompare(language) == .orderedSame
        }),
        let path = Bundle.module.path(forResource: localization, ofType: "lproj"),
        let bundle = Bundle(path: path) else { return key }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: locale, arguments: arguments)
    }
}
