import Foundation

struct PreferenceStore: Sendable {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var overrideBaseURL: URL? {
        get {
            guard let raw = defaults.string(forKey: AppPreferenceKey.dashboardBaseURL),
                let url = URL(string: raw)
            else { return nil }
            return url
        }
        nonmutating set {
            if let newValue {
                defaults.set(newValue.absoluteString, forKey: AppPreferenceKey.dashboardBaseURL)
            } else {
                defaults.removeObject(forKey: AppPreferenceKey.dashboardBaseURL)
            }
        }
    }

    var lastKnownBaseURL: URL? {
        get {
            guard let raw = defaults.string(forKey: AppPreferenceKey.lastKnownBaseURL),
                let url = URL(string: raw)
            else { return nil }
            return url
        }
        nonmutating set {
            if let newValue {
                defaults.set(newValue.absoluteString, forKey: AppPreferenceKey.lastKnownBaseURL)
            } else {
                defaults.removeObject(forKey: AppPreferenceKey.lastKnownBaseURL)
            }
        }
    }

    var historyRetentionHours: Double {
        get {
            let value = defaults.double(forKey: AppPreferenceKey.historyRetentionHours)
            return value > 0 ? value : 24
        }
        nonmutating set {
            defaults.set(newValue, forKey: AppPreferenceKey.historyRetentionHours)
        }
    }

    var historyRange: HistoryRange {
        get {
            guard let raw = defaults.string(forKey: AppPreferenceKey.historyRange),
                let range = HistoryRange(rawValue: raw)
            else {
                return .fiveMinutes
            }
            return range
        }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: AppPreferenceKey.historyRange)
        }
    }
}
