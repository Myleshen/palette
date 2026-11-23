import Foundation

/// A listing kept for a few seconds. The key carries whatever cheap
/// fingerprint invalidates it (a directory's mtime, the configured folders), so
/// a new capture or a settings change misses without a notification wiring.
public actor ShortCache<Value: Sendable> {
    private var entry: (key: String, value: Value, at: Date)?
    private let ttl: TimeInterval

    public init(ttl: TimeInterval) {
        self.ttl = ttl
    }

    public func get(_ key: String) -> Value? {
        guard let entry, entry.key == key, Date().timeIntervalSince(entry.at) < ttl else { return nil }
        return entry.value
    }

    public func set(_ value: Value, key: String) {
        entry = (key, value, Date())
    }

    public func invalidate() {
        entry = nil
    }
}

/// A provider whose preview costs a process call. The host shows the rows
/// first and asks for the selected row's preview afterwards, so a git or
/// network round trip never delays the list.
public protocol AsyncPreviewProviding: AnyObject, Sendable {
    /// The preview for `item`, or nil when the provider has nothing cheaper to
    /// say than the one already on the row.
    func preview(for item: PaletteItem) async -> ItemPreview?
}
