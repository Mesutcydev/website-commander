// Prints the CGWindowID of the frontmost normal-layer window owned by the
// process named in argv[1]. Used so screenshots capture the app window
// regardless of z-order.
import CoreGraphics
import Foundation

// Matched loosely: the bundle display name ("Website Commander") differs from
// the process name ("WebsiteCommander").
let target = (CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "WebsiteCommander")
    .replacingOccurrences(of: " ", with: "")
    .lowercased()

// Not `.optionOnScreenOnly`: the window may live on another Space while the
// capture still needs to find it by ID.
guard let windows = CGWindowListCopyWindowInfo(
    [.optionAll, .excludeDesktopElements], kCGNullWindowID
) as? [[String: Any]] else { exit(1) }

// Optional expected size (argv[2], argv[3]). A process can own several
// normal-layer windows — WebKit in particular keeps its own — so when a size is
// given, prefer the window that actually matches it. Otherwise take the largest.
let expected: CGSize? = {
    guard CommandLine.arguments.count > 3,
          let w = Double(CommandLine.arguments[2]),
          let h = Double(CommandLine.arguments[3])
    else { return nil }
    return CGSize(width: w, height: h)
}()

var candidates: [(id: Int, size: CGSize)] = []
for window in windows {
    let owner = (window[kCGWindowOwnerName as String] as? String ?? "")
        .replacingOccurrences(of: " ", with: "")
        .lowercased()
    guard owner == target,
          window[kCGWindowLayer as String] as? Int == 0,
          let bounds = window[kCGWindowBounds as String] as? [String: Any],
          let width = (bounds["Width"] as? NSNumber)?.doubleValue,
          let height = (bounds["Height"] as? NSNumber)?.doubleValue,
          width > 400, height > 300,
          let number = window[kCGWindowNumber as String] as? Int
    else { continue }
    candidates.append((number, CGSize(width: width, height: height)))
}

if let expected,
   let match = candidates.min(by: {
       abs($0.size.width - expected.width) + abs($0.size.height - expected.height)
           < abs($1.size.width - expected.width) + abs($1.size.height - expected.height)
   }),
   abs(match.size.width - expected.width) <= 8 {
    print(match.id)
    exit(0)
}

if let largest = candidates.max(by: { $0.size.width * $0.size.height < $1.size.width * $1.size.height }) {
    print(largest.id)
    exit(0)
}
exit(1)
