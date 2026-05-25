# Scoova Monitor — iOS SDK

Swift Package for crash reporting, analytics, performance, and battery
monitoring. iOS 14+, no Objective-C bridging required.

## Install

### Swift Package Manager (Xcode)

In Xcode → File → Add Packages → enter:

```
https://github.com/Scoova/scoova-monitor-ios
```

Select the `ScoovaMonitor` library and add it to your app target.

### Package.swift

```swift
.package(url: "https://github.com/Scoova/scoova-monitor-ios", from: "1.5.1")
```

Then:

```swift
.product(name: "ScoovaMonitor", package: "scoova-monitor-ios")
```

## Usage

Initialize as early as possible — typically in your `AppDelegate`:

```swift
import ScoovaMonitor

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        ScoovaMonitor.shared.initialize(apiKey: "sm_your_api_key")
        return true
    }
}
```

For SwiftUI apps, do it in your `App` struct's `init()`:

```swift
@main
struct MyApp: App {
    init() {
        ScoovaMonitor.shared.initialize(apiKey: "sm_your_api_key")
    }

    var body: some Scene { /* … */ }
}
```

## Configuration

```swift
let config = ScoovaMonitor.Config(
    endpoint: "https://monitor.scoo-va.info",   // self-hosted? change this
    flushInterval: 300,                          // seconds; default 5 min
    maxBatchSize: 50,
    enableSDKDetection: false                    // opt-in; default false
)

ScoovaMonitor.shared.initialize(apiKey: "sm_...", config: config)
```

### Privacy

The SDK does **not** read device GPS location and touches no location
APIs. Region (country / city) for analytics is resolved server-side from
the request IP at ingest — the raw IP is never stored.

`enableSDKDetection` is **off by default**. When enabled, once per install
the SDK probes for known third-party SDKs (Firebase, Sentry, Mixpanel,
Stripe, Google Maps, etc.) and emits a single `detected_sdks` event.
Useful for the SDK-adoption dashboard, never required for
crash / analytics / performance.

## API

### Identify the user

```swift
ScoovaMonitor.shared.setUserId("user_123")
```

The user ID is hashed before it leaves the device. If you don't call
`setUserId`, the SDK uses an anonymous installation ID so DAU/MAU and
retention still work.

### Track events

```swift
ScoovaMonitor.shared.trackEvent("checkout_started", data: [
    "plan": "annual",
    "amount": "29.99"
])
```

### Track screens

```swift
ScoovaMonitor.shared.trackScreen("ProductDetail")
```

### Log a non-fatal error

```swift
ScoovaMonitor.shared.logError(error, context: "uploading photo")
```

### Add breadcrumbs

```swift
ScoovaMonitor.shared.addBreadcrumb("Started photo upload", category: "media")
```

### Tagged loggers

```swift
let log = ScoovaMonitor.shared.logger(tag: "payment")
log.info("Started checkout", data: ["amount": "29.99"])
log.error("Card declined", data: ["code": "card_declined"])
```

### Right-to-erasure (GDPR / CCPA)

When the user deletes their account, wipe everything the SDK has stored on
this device:

```swift
ScoovaMonitor.shared.clearLocalUserData()
```

This drops queued events, the pending crash file, breadcrumbs, the
anonymous installation ID, and the session counter. Pair it with a
server-side `DELETE /v1/ingest/me/{userId}` to erase the server copy.

### Manual flush

```swift
ScoovaMonitor.shared.flush()
```

The SDK auto-flushes every 5 minutes, on app background, and when the
batch size threshold is hit — manual `flush()` is rarely needed.

## Symbolication

iOS crash reports arrive as raw memory addresses. To get readable stack
traces in the dashboard, each release build's **dSYM** files — the symbol
maps Xcode strips out of the shipping binary — need to be uploaded.

It's a **one-time setup**, then it runs automatically on every release
build (the same model Crashlytics uses). In Xcode: select your app target
→ **Build Phases** → **+** → **New Run Script Phase**, drag it **after**
the *Embed Frameworks* phase, and paste:

```sh
if [ "$CONFIGURATION" = "Release" ]; then
  SCRIPT="${BUILD_DIR%Build/*}SourcePackages/checkouts/scoova-monitor-ios/scripts/scoova-upload-dsyms.js"
  node "$SCRIPT" \
    --api-key "$SCOOVA_API_KEY" \
    --version "$MARKETING_VERSION" \
    --build "$CURRENT_PROJECT_VERSION" \
    --dir "$DWARF_DSYM_FOLDER_PATH"
fi
```

Add `SCOOVA_API_KEY` as a User-Defined Build Setting on the target (or
paste your key directly). That's the whole setup — every Release build now
uploads its own dSYMs.

The script ships **inside this Swift Package**, so it is already on disk
once you add the SDK — nothing extra to download. It needs Node on the
build machine (preinstalled on most Macs; CI runners may need a setup
step). It walks `$DWARF_DSYM_FOLDER_PATH` for `*.app.dSYM` bundles, zips
each, and uploads them to `/v1/upload/mapping`.

## Building from source

```bash
xcodebuild -scheme ScoovaMonitor -destination 'generic/platform=iOS' build
```

`swift build` won't work on macOS hosts (UIKit isn't available outside the
iOS SDK).

## Releasing

This mirror auto-publishes both distribution channels on a tag push:

- **SwiftPM** — the git tag itself is the release. Xcode resolves
  `from: "1.5.2"` directly from the tag, no extra step.
- **CocoaPods** — the [`.github/workflows/publish-cocoapods.yml`](.github/workflows/publish-cocoapods.yml)
  workflow fires when a plain SemVer tag (e.g. `1.5.2`) is pushed.
  It verifies the tag matches `s.version` in `ScoovaMonitor.podspec`,
  authenticates with the long-lived `POD_TRUNK_TOKEN` repo secret, runs
  `pod lib lint --quick`, then `pod trunk push` and finally polls the
  trunk API to confirm the version landed.

Release ritual:

```bash
# 1. bump ScoovaMonitor.podspec → s.version = '1.5.2'
# 2. bump CHANGELOG.md
# 3. sync Sources/ from the monorepo's sdk-ios/Sources/ if there are
#    SDK changes (rsync -avz --delete ../scoova-monitor/sdk-ios/Sources/ ./Sources/)
git add -A
git commit -m "1.5.2"
git tag 1.5.2 HEAD
git push origin main 1.5.2
```

Both channels are live within ~30s of the tag landing on GitHub.

The full release procedure across all 5 SDKs is documented at
[`scoova-monitor/RELEASING.md`](https://github.com/zaidzedoo007/scoova-monitor/blob/main/RELEASING.md)
in the monorepo (private).

## License

[Apache 2.0](../LICENSE).
