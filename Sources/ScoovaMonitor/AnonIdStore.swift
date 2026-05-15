import Foundation

/// Persistent anonymous installation ID — generated once per app install,
/// stored in UserDefaults, and used as the user_id fallback when the host
/// app hasn't called setUserId(). Lets DAU/MAU/retention/sessions still count
/// something distinct per device for apps without a login system.
///
/// The ID is opaque — never derived from IDFA/IDFV/device fingerprints — so
/// it doesn't survive app uninstall and isn't shared across apps from the
/// same vendor.
internal enum AnonIdStore {

    private static let key = "scoova_monitor_anon_id"
    private static let prefix = "anon_"

    private static var cached: String?

    private static func resolveOrCreate() -> String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: key), existing.hasPrefix(prefix) {
            return existing
        }
        let fresh = prefix + UUID().uuidString.lowercased()
        defaults.set(fresh, forKey: key)
        return fresh
    }

    /// Force resolution at init time — value is also lazy-computed on first get().
    static func initialize() {
        if cached == nil { cached = resolveOrCreate() }
    }

    /// Returns the cached anon ID. Always non-nil after first call.
    /// If the cache has been reset (or first call after install), regenerates.
    static func get() -> String? {
        if cached == nil { cached = resolveOrCreate() }
        return cached
    }

    /// Reset — wipe the persisted ID and the in-memory cache. Used by
    /// clearLocalUserData(). The next event will lazily generate a fresh
    /// anon ID, exactly as if the user had reinstalled the app.
    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
        cached = nil
    }
}
