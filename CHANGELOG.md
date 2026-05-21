# Changelog

## 1.5.1 — 2026-05-21

### Fixed
- Log-batch uploads (`/v1/ingest/logs/batch`) now send the `X-Bundle-Id`
  header, like every other ingest path. The server uses it to confirm
  data came from the app registered to the API key.

## 1.5.0 — 2026-05-21

### Added
- `getInstallDate()` — UserDefaults timestamp on first run, mirrors
  Android's `PackageInfo.firstInstallTime`. Forwarded as
  `device.installDate`.
- `getGpuRenderer()` — Metal device name via
  `MTLCreateSystemDefaultDevice`. Permission-free.
- `getNetworkGeneration()` — `2G` / `3G` / `4G` / `5G` mapping from
  `CTTelephonyNetworkInfo`. Returns `nil` on iOS 16+ where Apple
  deprecated the API; same behaviour as BugSnag.

### Changed
- SDK version reported as `1.5.0` in every event payload.
- Carrier remains `nil` on iOS 16+ — Apple deprecated `CTCarrier`. Same
  behaviour as the BugSnag iOS SDK.

## 1.4.0

Initial public release.
