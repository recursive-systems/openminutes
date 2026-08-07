import Foundation

enum SummaryPreferences {
    static let enabledKey = "summariesEnabled"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }
}
