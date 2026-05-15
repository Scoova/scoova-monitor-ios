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
.package(url: "https://github.com/Scoova/scoova-monitor-ios", from: "1.4.0")
```

Then:

```swift
.product(name: "ScoovaMonitor", package: "scoova-monitor")
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
anonymous installation ID, the session counter, and any cached location.
Pair it with a server-side `DELETE /v1/ingest/me/{userId}` to erase the
server copy.

### Manual flush

```swift
ScoovaMonitor.shared.flush()
```

The SDK auto-flushes every 5 minutes, on app background, and when the
batch size threshold is hit — manual `flush()` is rarely needed.

## Symbolication

Upload `.dSYM` archives so server-side stack traces are de-obfuscated:

```bash
node sdk-ios/scripts/scoova-upload-dsyms.js \
    --api-key sm_your_api_key \
    --version 1.0.0 \
    --build 42 \
    --dir "$DWARF_DSYM_FOLDER_PATH"
```

The script walks `--dir` for `*.app.dSYM` bundles, zips each one with the
system `zip` binary, and uploads to `/v1/upload/mapping`. Wire it into a
Run Script Build Phase in Xcode (after the *Embed Frameworks* phase) —
run the script with `--help` for the exact snippet.

## Building from source

```bash
xcodebuild -scheme ScoovaMonitor -destination 'generic/platform=iOS' build
```

`swift build` won't work on macOS hosts (UIKit isn't available outside the
iOS SDK).

## License

[Apache 2.0](LICENSE).
