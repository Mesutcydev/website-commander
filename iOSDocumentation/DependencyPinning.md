# Dependency pinning

SiteAgent resolves Swift packages from the `from:` lower bounds in `project.yml`.
`Package.resolved` is **tracked in git** (not ignored) so CI and local builds
reproduce the same dependency graph.

## After changing package versions

```sh
# Generate / refresh the lockfile with the same Xcode you ship with:
xcodebuild -resolvePackageDependencies -project SiteAgent.xcodeproj -scheme SiteAgent
# or, after `xcodegen generate`:
swift package resolve   # if using a Package.swift workspace

git add Package.resolved
git commit -m "Pin SPM dependencies"
```

Never delete `Package.resolved` from the repo. Floating resolution was previously
a HIGH supply-chain risk (see security remediation).
