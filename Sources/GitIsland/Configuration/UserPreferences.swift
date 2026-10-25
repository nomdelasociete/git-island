import Foundation

enum UserPreferences {
    // Separate trusted origins: relay never handles enrollment or refresh secrets.
    // Credential destinations are deployment trust anchors, not mutable preferences.
    static let officialRelayOrigin = "https://relay.nomdelasociete.com"
    static let relayAuthorityOrigin = "https://access.relay.nomdelasociete.com"
    static let relayBrowserOrigin = "https://auth.relay.nomdelasociete.com"

    static var relayInboxEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "relayInboxEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "relayInboxEnabled") }
    }

    static var relayOrigin: String {
        get { UserDefaults.standard.string(forKey: "relayOrigin") ?? officialRelayOrigin }
        set { UserDefaults.standard.set(newValue, forKey: "relayOrigin") }
    }

    private static let refreshIntervalKey = "refreshIntervalSeconds"
    private static let legacyRefreshIntervalKey = "refreshIntervalMinutes"
    private static let repositoryFilterModeKey = "repositoryFilterMode"
    private static let selectedRepositoryFullNamesKey = "selectedRepositoryFullNames"
    private static let mutedRepositoryFullNamesKey = "mutedRepositoryFullNames"
    private static let hiddenPullRequestsKey = "hiddenPullRequests"
    private static let crazyAnimationsEnabledKey = "crazyAnimationsEnabled"
    private static let eventSoundsKey = "eventSounds"
    private static let outlineLaneWidthKey = "outlineLaneWidth"
    private static let outlineLaneGapKey = "outlineLaneGap"
    private static let maxOutlineLanesKey = "maxOutlineLanes"

    static var refreshIntervalSeconds: Int {
        get {
            let defaults = UserDefaults.standard

            if defaults.object(forKey: refreshIntervalKey) != nil {
                let storedSeconds = defaults.integer(forKey: refreshIntervalKey)
                if RefreshIntervalOption(rawValue: storedSeconds) != nil {
                    return storedSeconds
                }
            }

            if defaults.object(forKey: legacyRefreshIntervalKey) != nil {
                let legacyMinutes = defaults.integer(forKey: legacyRefreshIntervalKey)
                if legacyMinutes == 5 {
                    return RefreshIntervalOption.oneMinute.rawValue
                }

                if legacyMinutes > 0 {
                    return legacyMinutes * 60
                }
            }

            return RefreshIntervalOption.oneMinute.rawValue
        }
        set {
            UserDefaults.standard.set(newValue, forKey: refreshIntervalKey)
        }
    }

    static var repositoryFilterMode: RepositoryFilterMode {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: repositoryFilterModeKey),
                  let mode = RepositoryFilterMode(rawValue: rawValue)
            else {
                return .all
            }

            return mode
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: repositoryFilterModeKey)
        }
    }

    static var selectedRepositoryFullNames: [String] {
        get {
            let stored = UserDefaults.standard.array(forKey: selectedRepositoryFullNamesKey) as? [String] ?? []
            return normalizedRepositoryFullNames(stored)
        }
        set {
            UserDefaults.standard.set(
                normalizedRepositoryFullNames(newValue),
                forKey: selectedRepositoryFullNamesKey
            )
        }
    }

    static var mutedRepositoryFullNames: [String] {
        get {
            let stored = UserDefaults.standard.array(forKey: mutedRepositoryFullNamesKey) as? [String] ?? []
            return normalizedRepositoryFullNames(stored)
        }
        set {
            UserDefaults.standard.set(
                normalizedRepositoryFullNames(newValue),
                forKey: mutedRepositoryFullNamesKey
            )
        }
    }

    static var hiddenPullRequests: [HiddenPullRequest] {
        get {
            guard let data = UserDefaults.standard.data(forKey: hiddenPullRequestsKey),
                  let stored = try? JSONDecoder().decode([HiddenPullRequest].self, from: data)
            else {
                return []
            }
            return stored
        }
        set {
            var byID: [Int: HiddenPullRequest] = [:]
            for pullRequest in newValue {
                byID[pullRequest.id] = pullRequest
            }
            let unique = byID.values.sorted {
                if $0.repositoryFullName != $1.repositoryFullName {
                    return $0.repositoryFullName < $1.repositoryFullName
                }
                return $0.number < $1.number
            }
            guard let data = try? JSONEncoder().encode(unique) else {
                return
            }
            UserDefaults.standard.set(data, forKey: hiddenPullRequestsKey)
        }
    }

    static var crazyAnimationsEnabled: Bool {
        get {
            UserDefaults.standard.bool(forKey: crazyAnimationsEnabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: crazyAnimationsEnabledKey)
        }
    }

    static var outlineLaneStyle: OutlineLaneStyle {
        get {
            let defaults = UserDefaults.standard
            let standard = OutlineLaneStyle.standard
            return OutlineLaneStyle(
                width: defaults.object(forKey: outlineLaneWidthKey) == nil
                    ? standard.width : CGFloat(defaults.double(forKey: outlineLaneWidthKey)),
                gap: defaults.object(forKey: outlineLaneGapKey) == nil
                    ? standard.gap : CGFloat(defaults.double(forKey: outlineLaneGapKey)),
                maxLanes: defaults.object(forKey: maxOutlineLanesKey) == nil
                    ? standard.maxLanes : defaults.integer(forKey: maxOutlineLanesKey)
            ).clamped()
        }
        set {
            let defaults = UserDefaults.standard
            defaults.set(Double(newValue.width), forKey: outlineLaneWidthKey)
            defaults.set(Double(newValue.gap), forKey: outlineLaneGapKey)
            defaults.set(newValue.maxLanes, forKey: maxOutlineLanesKey)
        }
    }

    /// Every event defaults to no sound.
    static var eventSounds: [IslandSoundEvent: IslandSoundChoice] {
        get {
            let stored = UserDefaults.standard.dictionary(forKey: eventSoundsKey) as? [String: String] ?? [:]
            return stored.reduce(into: [:]) { sounds, entry in
                guard let event = IslandSoundEvent(rawValue: entry.key) else { return }
                sounds[event] = IslandSoundChoice(storageValue: entry.value)
            }
        }
        set {
            let stored = newValue.reduce(into: [String: String]()) { stored, entry in
                stored[entry.key.rawValue] = entry.value.storageValue
            }
            UserDefaults.standard.set(stored, forKey: eventSoundsKey)
        }
    }

    static func normalizedRepositoryFullName(_ value: String) -> String? {
        var normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "https://github.com/", with: "")
            .replacingOccurrences(of: "http://github.com/", with: "")
            .replacingOccurrences(of: "git@github.com:", with: "")

        if normalized.hasSuffix(".git") {
            normalized.removeLast(4)
        }

        normalized = normalized.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        let parts = normalized.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 2 else {
            return nil
        }

        let owner = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let name = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !owner.isEmpty, !name.isEmpty else {
            return nil
        }

        return "\(owner)/\(name)".lowercased()
    }

    private static func normalizedRepositoryFullNames(_ values: [String]) -> [String] {
        Array(Set(values.compactMap(normalizedRepositoryFullName))).sorted()
    }
}

enum RepositoryFilterMode: String, CaseIterable, Identifiable {
    case all
    case selected

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all:
            "All repositories"
        case .selected:
            "Selected repositories"
        }
    }
}

enum RefreshIntervalOption: Int, CaseIterable, Identifiable {
    case thirtySeconds = 30
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .thirtySeconds:
            "Every 30 seconds"
        case .oneMinute:
            "Every minute"
        case .fiveMinutes:
            "Every 5 minutes"
        case .fifteenMinutes:
            "Every 15 minutes"
        }
    }
}
