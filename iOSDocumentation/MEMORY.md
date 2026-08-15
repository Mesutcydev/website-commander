# Project Environment

- `is_react_native`: false
- `is_native_ios`: true
- `is_native_android`: false
- Build: `xcodegen generate`; `xcodebuild -project SiteAgent.xcodeproj -scheme SiteAgent -configuration Debug -destination 'generic/platform=iOS Simulator' build`
- Tests: `xcodebuild -project SiteAgent.xcodeproj -scheme SiteAgent -configuration Debug -destination 'platform=iOS Simulator,name=<available simulator>' test`
- Additional archive: `xcodebuild -project SiteAgent.xcodeproj -scheme SiteAgent -configuration AppStore -destination 'generic/platform=iOS' clean archive -archivePath Build/SiteAgent.xcarchive`
- Targets: `SiteAgent`, `SiteAgentTests`; schemes: `SiteAgent`, `SiteAgent-PCC`
- Supports iOS 17+ and Mac Catalyst; no Android or Metro setup.
