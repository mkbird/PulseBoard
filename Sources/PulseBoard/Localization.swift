import Combine
import Foundation

private final class PulseBoardResourceBundleToken: NSObject {}

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
    private static let resourceBundle: Bundle = {
        let resourceBundleName = "PulseBoard_PulseBoard.bundle"
        let containingBundle = Bundle(for: PulseBoardResourceBundleToken.self)
        var origins = [Bundle.main.bundleURL, containingBundle.bundleURL]

        if let resourceURL = Bundle.main.resourceURL {
            origins.append(resourceURL)
        }
        if let executableURL = Bundle.main.executableURL {
            origins.append(executableURL.deletingLastPathComponent())
        }
        if let resourceURL = containingBundle.resourceURL {
            origins.append(resourceURL)
        }
        if let launchPath = CommandLine.arguments.first, !launchPath.isEmpty {
            origins.append(URL(fileURLWithPath: launchPath).deletingLastPathComponent())
        }

        var searchDirectories: [URL] = []
        for origin in origins {
            var directory = origin
            for _ in 0..<6 {
                searchDirectories.append(directory)
                directory.deleteLastPathComponent()
            }
        }

        for directory in searchDirectories {
            let candidate = directory.appendingPathComponent(resourceBundleName, isDirectory: true)
            if let bundle = Bundle(url: candidate) {
                return bundle
            }
        }

        // Missing localization resources must never prevent the app from launching.
        return Bundle.main
    }()

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
            Locale(identifier: resourceBundle.preferredLocalizations.first ?? Locale.current.identifier)
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
        case .system: resourceBundle
        case .simplifiedChinese, .english:
            localizedBundle(for: language.rawValue) ?? resourceBundle
        }
    }

    private static func localizedBundle(for language: String) -> Bundle? {
        guard let localization = resourceBundle.localizations.first(where: {
            $0.caseInsensitiveCompare(language) == .orderedSame
        }),
        let path = resourceBundle.path(forResource: localization, ofType: "lproj") else { return nil }
        return Bundle(path: path)
    }
}
