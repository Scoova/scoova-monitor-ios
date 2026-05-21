Pod::Spec.new do |s|
  s.name             = 'ScoovaMonitor'
  s.version          = '1.5.0'
  s.summary          = 'Crash reporting, analytics, performance, and logging for iOS apps.'

  s.description      = <<-DESC
    Scoova Monitor iOS SDK — crash reporting, analytics, performance metrics,
    battery monitoring, and structured logging. Pure Swift, no third-party
    dependencies. User IDs are SHA-256 hashed on-device; the SDK reads no
    location APIs.
  DESC

  s.homepage         = 'https://monitor.scoo-va.info'
  s.license          = { :type => 'Apache-2.0', :file => 'LICENSE' }
  s.author           = { 'Scoova' => 'dev@scoo-va.info' }
  s.source           = { :git => 'https://github.com/Scoova/scoova-monitor-ios.git', :tag => s.version.to_s }

  s.ios.deployment_target = '14.0'
  s.swift_versions   = ['5.9']

  s.source_files     = 'Sources/ScoovaMonitor/**/*.swift'

  # The dSYM upload script ships with the pod — see README → Symbolication.
  # CocoaPods installs it to Pods/ScoovaMonitor/scripts/.
  s.preserve_paths   = 'scripts/**/*'
end
