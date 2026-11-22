import AppKit

/// LanKvm — use one Mac keyboard and mouse to drive a Windows PC on the same
/// network, with mouse edge crossing and clipboard sync.
///
/// The app lives in the menu bar. It supervises the input helper, which holds
/// the Accessibility permission and performs the actual event capture.
///
/// This is top-level code, so it runs on the main thread before the run loop
/// starts; `assumeIsolated` states that to the concurrency checker.

let application = NSApplication.shared
application.setActivationPolicy(.accessory)

MainActor.assumeIsolated {
    let controller = AppController.shared
    controller.start()

    // A minimal main menu keeps the standard shortcuts working in the settings
    // window. Items target the controller directly because it is not part of
    // the responder chain.
    let mainMenu = NSMenu()
    let appMenuItem = NSMenuItem()
    mainMenu.addItem(appMenuItem)

    let appMenu = NSMenu()
    appMenu.addItem(
        withTitle: "关于 LanKvm",
        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
        keyEquivalent: ""
    )
    appMenu.addItem(.separator())

    let settingsItem = NSMenuItem(
        title: "设置…",
        action: #selector(AppController.openSettings),
        keyEquivalent: ","
    )
    settingsItem.target = controller
    appMenu.addItem(settingsItem)

    appMenu.addItem(.separator())
    appMenu.addItem(
        withTitle: "退出 LanKvm",
        action: #selector(NSApplication.terminate(_:)),
        keyEquivalent: "q"
    )
    appMenuItem.submenu = appMenu
    application.mainMenu = mainMenu
}

application.run()
