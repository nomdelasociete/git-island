import Foundation

struct AppVersion: Equatable {
    let version: String
    let build: String

    static let current = AppVersion(info: Bundle.main.infoDictionary ?? [:])

    init(info: [String: Any]) {
        version = Self.value(info["CFBundleShortVersionString"]) ?? "Development"
        build = Self.value(info["CFBundleVersion"]) ?? "Unbundled"
    }

    private static func value(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }
}
