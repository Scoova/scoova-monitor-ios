import Foundation
#if canImport(AdServices)
import AdServices
#endif

/// Auto-detects iOS install attribution on first launch and reports
/// it once via the existing `install_info` event the server already
/// understands.
///
/// Flow on first launch (and only first launch — `sm_install_attr`
/// in UserDefaults guards against re-running):
///
///   1. Ask Apple's `AAAttribution.attributionToken()` for the
///      one-time-use token (requires iOS 14.3+).
///   2. POST that token to `https://api-adservices.apple.com/api/v1`
///      and parse the resulting JSON. Apple's response includes
///      `attribution: true/false` (paid vs organic),
///      `campaignId` / `adGroupId` / `keywordId` if paid via Apple
///      Search Ads, plus a coarse country/region.
///   3. Map Apple's response into our two canonical fields:
///        - `install_source`: "apple_search_ads" (paid) /
///          "organic" (attribution=false) / "unknown" (token failed)
///        - `install_campaign`: the campaignId, or empty
///   4. Fire one `install_info` event via the existing batcher.
///
/// Apple's attribution API is best-effort and rate-limited per device;
/// any non-success path lands as `install_source = "unknown"` so the
/// server still records the install and the dashboard's bucket count
/// is correct. The token is good for one HTTP call only — we burn it
/// once and the result is permanent.
internal enum InstallAttribution {

    private static let key = "sm_install_attr_done"

    /// Capture and report install attribution exactly once per device.
    /// Call this from `ScoovaMonitor.initialize` — the guard makes it
    /// idempotent across re-inits within the same install.
    static func captureIfNeeded(reporter: @escaping (_ source: String, _ campaign: String?) -> Void) {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: key) { return }

        // Mark immediately so a second call (e.g. host re-inits in
        // SwiftUI preview) doesn't run twice. We accept that if the
        // network call below fails, we'll have an empty attribution
        // for this install — that's a deliberate trade for not
        // over-counting acquisitions.
        defaults.set(true, forKey: key)

        Task.detached(priority: .background) {
            let result = await resolveAttribution()
            await MainActor.run {
                reporter(result.source, result.campaign)
            }
        }
    }

    private struct Resolution {
        let source: String
        let campaign: String?
    }

    private static func resolveAttribution() async -> Resolution {
        #if canImport(AdServices)
        if #available(iOS 14.3, *) {
            // Step 1: ask Apple for the token.
            let token: String
            do {
                token = try AAAttribution.attributionToken()
            } catch {
                return Resolution(source: "unknown", campaign: nil)
            }

            // Step 2: POST token to Apple's attribution API.
            guard let url = URL(string: "https://api-adservices.apple.com/api/v1") else {
                return Resolution(source: "unknown", campaign: nil)
            }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("text/plain", forHTTPHeaderField: "Content-Type")
            req.httpBody = token.data(using: .utf8)
            req.timeoutInterval = 10

            let data: Data
            do {
                let (d, _) = try await URLSession.shared.data(for: req)
                data = d
            } catch {
                return Resolution(source: "unknown", campaign: nil)
            }

            // Step 3: parse Apple's JSON. Shape (per Apple docs):
            //   { "attribution": true/false,
            //     "orgId": 12345, "campaignId": 67890,
            //     "conversionType": "Download" / "Redownload",
            //     "clickDate": "...", "adGroupId": 11, "countryOrRegion": "US",
            //     "keywordId": 22, "adId": 33 }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return Resolution(source: "unknown", campaign: nil)
            }

            let isPaid = (json["attribution"] as? Bool) ?? false
            if isPaid {
                let campaignId = (json["campaignId"] as? Int).map { String($0) }
                return Resolution(source: "apple_search_ads", campaign: campaignId)
            } else {
                return Resolution(source: "organic", campaign: nil)
            }
        }
        #endif
        return Resolution(source: "unknown", campaign: nil)
    }
}
