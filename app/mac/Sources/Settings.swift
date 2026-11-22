import AppKit
import Foundation

/// Persisted user settings. Stored in UserDefaults so the app needs no config
/// file and survives updates.
enum Settings {
    private static let hostKey = "windowsHost"
    private static let portKey = "windowsPort"
    private static let tokenKey = "windowsToken"

    static func loadTarget() -> LanKvmTarget? {
        guard let host = loadHost(), !host.isEmpty,
              let port = loadPort(),
              let token = loadToken(), !token.isEmpty else { return nil }
        return LanKvmTarget(host: host, port: port, token: token)
    }

    static func saveTarget(_ target: LanKvmTarget) {
        UserDefaults.standard.set(target.host, forKey: hostKey)
        UserDefaults.standard.set(target.port, forKey: portKey)
        UserDefaults.standard.set(target.token, forKey: tokenKey)
    }

    static func loadHost() -> String? { UserDefaults.standard.string(forKey: hostKey) }
    static func saveHost(_ host: String) { UserDefaults.standard.set(host, forKey: hostKey) }

    static func loadPort() -> Int? {
        let value = UserDefaults.standard.integer(forKey: portKey)
        return value >= 1024 && value <= 65535 ? value : 7681
    }
    static func savePort(_ port: Int) { UserDefaults.standard.set(port, forKey: portKey) }

    static func loadToken() -> String? { UserDefaults.standard.string(forKey: tokenKey) }
    static func saveToken(_ token: String) { UserDefaults.standard.set(token, forKey: tokenKey) }

    static func openAccessibility() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Settings window: address, token, and the permission state.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    private weak var controller: AppController?
    private var window: NSWindow?
    private let hostField = NSTextField()
    private let portField = NSTextField()
    private let tokenField = NSTextField()
    private let statusLabel = NSTextField(labelWithString: "")

    init(controller: AppController) {
        self.controller = controller
        super.init()
        build()
    }

    private func build() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "LanKvm 设置"
        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false

        let content = NSView(frame: window.contentView?.bounds ?? .zero)
        content.autoresizingMask = [.width, .height]
        var y: CGFloat = 240

        func addLabel(_ text: String, at: CGFloat) {
            let label = NSTextField(labelWithString: text)
            label.frame = NSRect(x: 20, y: at, width: 120, height: 20)
            content.addSubview(label)
        }
        func addField(_ field: NSTextField, at: CGFloat) {
            field.frame = NSRect(x: 145, y: at - 3, width: 295, height: 24)
            content.addSubview(field)
        }

        addLabel("Windows 地址", at: y)
        hostField.placeholderString = "192.168.1.20"
        hostField.stringValue = Settings.loadHost() ?? ""
        addField(hostField, at: y)
        y -= 36

        addLabel("端口", at: y)
        portField.placeholderString = "7681"
        portField.stringValue = String(Settings.loadPort() ?? 7681)
        addField(portField, at: y)
        y -= 36

        addLabel("令牌", at: y)
        tokenField.placeholderString = "Windows 窗口里显示的令牌"
        tokenField.stringValue = Settings.loadToken() ?? ""
        addField(tokenField, at: y)
        y -= 44

        let hint = NSTextField(wrappingLabelWithString:
            "在 Windows 上打开 LanKvm.exe，把窗口里显示的地址和令牌填到这里。")
        hint.frame = NSRect(x: 20, y: y - 30, width: 420, height: 44)
        hint.textColor = .secondaryLabelColor
        content.addSubview(hint)
        y -= 74

        statusLabel.frame = NSRect(x: 20, y: y, width: 420, height: 20)
        statusLabel.textColor = .secondaryLabelColor
        content.addSubview(statusLabel)
        y -= 44

        let save = NSButton(title: "保存并连接", target: self, action: #selector(saveAndConnect))
        save.frame = NSRect(x: 20, y: y, width: 150, height: 32)
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        content.addSubview(save)

        let scan = NSButton(title: "搜索局域网", target: self, action: #selector(scan))
        scan.frame = NSRect(x: 180, y: y, width: 160, height: 32)
        scan.bezelStyle = .rounded
        content.addSubview(scan)

        let permission = NSButton(title: "辅助功能权限…", target: self, action: #selector(openAccessibility))
        permission.frame = NSRect(x: 350, y: y, width: 130, height: 32)
        permission.bezelStyle = .rounded
        content.addSubview(permission)

        window.contentView = content
        self.window = window
        refreshStatus()
    }

    func suggestHost(_ host: String) { hostField.stringValue = host }

    func show() {
        hostField.stringValue = Settings.loadHost() ?? hostField.stringValue
        portField.stringValue = String(Settings.loadPort() ?? 7681)
        tokenField.stringValue = Settings.loadToken() ?? tokenField.stringValue
        refreshStatus()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func refreshStatus() {
        guard let controller else { return }
        if !controller.trusted {
            statusLabel.stringValue = "⚠︎ 请先授予 LanKvm 辅助功能权限，然后再连接。"
        } else if controller.connected {
            statusLabel.stringValue = "已连接。"
        } else {
            statusLabel.stringValue = "就绪。"
        }
    }

    @objc private func saveAndConnect() {
        let host = hostField.stringValue.trimmingCharacters(in: .whitespaces)
        let token = tokenField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, !token.isEmpty else {
            statusLabel.stringValue = "请填写地址和令牌。"
            return
        }
        let port = Int(portField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 7681
        guard port >= 1024, port <= 65535 else {
            statusLabel.stringValue = "端口需要在 1024 到 65535 之间。"
            return
        }
        statusLabel.stringValue = "正在连接…"
        Task {
            await controller?.connect(to: LanKvmTarget(host: host, port: port, token: token))
            refreshStatus()
        }
    }

    @objc private func scan() {
        statusLabel.stringValue = "正在扫描局域网…"
        Task {
            let port = Int(portField.stringValue) ?? 7681
            let found = await controller?.scanLan(port: port) ?? []
            if let first = found.first {
                hostField.stringValue = first.host
                refreshStatus()
            } else {
                statusLabel.stringValue = "没有找到 LanKvm 接收端。"
            }
        }
    }

    @objc private func openAccessibility() {
        // Show the system prompt so LanKvm appears in the Accessibility list.
        controller?.ensureAccessibilityPermission(prompt: true)
        Settings.openAccessibility()
        refreshStatus()
    }
}
