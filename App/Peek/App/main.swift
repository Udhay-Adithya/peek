import AppKit

// Explicit AppKit entry point rather than SwiftUI's `App` lifecycle.
// Peek needs a non-activating NSPanel that is fully constructed before the
// first invocation, and precise control over activation policy — neither is
// expressible through SwiftUI scenes without fighting them.
// Read before anything else, so launch timing covers the whole startup path.
_ = PerformanceHarness.processStart

let application = NSApplication.shared
let controller = AppDelegate()
application.delegate = controller
application.run()
