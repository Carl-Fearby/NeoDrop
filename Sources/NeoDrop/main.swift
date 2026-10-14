import AppKit

// The main thread is the main actor, so this is safe; `assumeIsolated` just tells the type
// checker what top-level code in a main.swift file cannot express on its own.
MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    // `.accessory` keeps NeoDrop out of the Dock and the app switcher: it lives in the title bar
    // only. The packaged bundle sets LSUIElement for the same effect when launched from Finder.
    application.setActivationPolicy(.accessory)
    application.run()
}
