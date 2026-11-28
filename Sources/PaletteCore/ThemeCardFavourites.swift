import Foundation

/// Favourites are a set of card cache keys in UserDefaults: small, plain and
/// readable, and no new file format. Injected defaults keep tests off the real
/// domain.
public struct ThemeCardFavourites {
    public static let defaultsKey = "themeCardFavourites"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var keys: Set<String> {
        Set(defaults.stringArray(forKey: Self.defaultsKey) ?? [])
    }

    public func save(_ keys: Set<String>) {
        defaults.set(keys.sorted(), forKey: Self.defaultsKey)
    }

    @discardableResult
    public func toggle(_ key: String) -> Set<String> {
        var value = keys
        if value.contains(key) {
            value.remove(key)
        } else {
            value.insert(key)
        }
        save(value)
        return value
    }
}
