import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    objc_setAssociatedObject(app, "io.tumanov.impuls.delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
    app.run()
}
