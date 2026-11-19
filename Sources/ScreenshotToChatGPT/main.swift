import AppKit
import ApplicationServices
import Carbon
import SwiftUI

private let hotKeySignature: OSType = 0x53534750
private let hotKeyID: UInt32 = 1

enum Destination: String, CaseIterable, Identifiable {
    case newChat, currentChat
    var id: String { rawValue }
    var label: String { self == .newChat ? "A new chat" : "The chat currently open" }
}

enum ShortcutChoice: String, CaseIterable, Identifiable {
    case commandShift8, commandOptionS, controlShiftS
    var id: String { rawValue }
    var label: String {
        switch self {
        case .commandShift8: return "⌘ ⇧ 8"
        case .commandOptionS: return "⌘ ⌥ S"
        case .controlShiftS: return "⌃ ⇧ S"
        }
    }
    var keyCode: UInt32 {
        self == .commandShift8 ? UInt32(kVK_ANSI_8) : UInt32(kVK_ANSI_S)
    }
    var modifiers: UInt32 {
        switch self {
        case .commandShift8: return UInt32(cmdKey | shiftKey)
        case .commandOptionS: return UInt32(cmdKey | optionKey)
        case .controlShiftS: return UInt32(controlKey | shiftKey)
        }
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    @AppStorage("destination") var destinationRaw = Destination.newChat.rawValue
    @AppStorage("shortcut") var shortcutRaw = ShortcutChoice.commandShift8.rawValue
    @AppStorage("autoSend") var autoSend = true
    @AppStorage("prompt") var prompt = "Please help me with what is shown in this screenshot."

    var destination: Destination { Destination(rawValue: destinationRaw) ?? .newChat }
    var shortcut: ShortcutChoice { ShortcutChoice(rawValue: shortcutRaw) ?? .commandShift8 }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = SettingsStore()
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var isCapturing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        createMenuBarItem()
        installHotKeyHandler()
        registerHotKey()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.registerHotKey()
                self?.updateMenu()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    private func createMenuBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = menuBarIcon()
        updateMenu()
    }

    private func menuBarIcon() -> NSImage? {
        guard let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: iconURL) else {
            return NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "Screenshot to ChatGPT")
        }
        icon.size = NSSize(width: 18, height: 18)
        icon.accessibilityDescription = "Screenshot to ChatGPT"
        return icon
    }

    private func updateMenu() {
        let menu = NSMenu()
        let capture = NSMenuItem(title: "Capture and send", action: #selector(captureAndSend), keyEquivalent: "")
        capture.target = self
        menu.addItem(capture)
        menu.addItem(.separator())
        for title in ["Destination: \(settings.destination.label)", "Shortcut: \(settings.shortcut.label)"] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func installHotKeyHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return noErr }
            var hotKey = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            guard hotKey.signature == hotKeySignature, hotKey.id == hotKeyID else { return noErr }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            Task { @MainActor in delegate.captureAndSend() }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
    }

    private func registerHotKey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        let choice = settings.shortcut
        let identifier = EventHotKeyID(signature: hotKeySignature, id: hotKeyID)
        let result = RegisterEventHotKey(choice.keyCode, choice.modifiers, identifier, GetApplicationEventTarget(), 0, &hotKeyRef)
        if result != noErr {
            showAlert(title: "Shortcut unavailable", message: "\(choice.label) is already used. Choose another shortcut in Settings.")
        }
    }

    @objc private func captureAndSend() {
        guard !isCapturing else { return }
        isCapturing = true
        statusItem.button?.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Capturing")
        Task {
            defer {
                isCapturing = false
                statusItem.button?.image = menuBarIcon()
            }
            do {
                guard let image = try await ScreenshotCapture.captureInteractive() else { return }
                try await ChatGPTDelivery.send(image: image, settings: settings)
            } catch {
                showAlert(title: "Couldn’t send screenshot", message: error.localizedDescription)
            }
        }
    }

    @objc func sendToChatGPT(
        _ pasteboard: NSPasteboard,
        userData: String,
        error errorPointer: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        guard let payload = ContextPayload.read(from: pasteboard) else {
            errorPointer.pointee = "Select an image, file, or text before choosing Send to ChatGPT."
            return
        }

        Task {
            do {
                try await ChatGPTDelivery.send(
                    payload: payload,
                    settings: settings,
                    includePrompt: !payload.isText
                )
            } catch {
                showAlert(title: "Couldn’t send selection", message: error.localizedDescription)
            }
        }
    }

    @objc private func showSettings() {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = NSHostingController(rootView: SettingsView(store: settings))
        let window = NSWindow(contentViewController: controller)
        window.title = "Screenshot to ChatGPT Settings"
        window.setContentSize(NSSize(width: 520, height: 440))
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

enum DeliveryError: LocalizedError {
    case captureFailed, chatGPTNotInstalled, accessibilityRequired
    var errorDescription: String? {
        switch self {
        case .captureFailed: return "macOS did not return a screenshot."
        case .chatGPTNotInstalled: return "The ChatGPT macOS app is not installed in Applications."
        case .accessibilityRequired: return "macOS does not currently recognize this copy as approved. In System Settings → Privacy & Security → Accessibility, remove any old “Screenshot to ChatGPT” entry, add this app again, then quit and reopen it."
        }
    }
}

enum ScreenshotCapture {
    static func captureInteractive() async throws -> NSImage? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ss-to-gpt-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-o", url.path]
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus == 1 { return nil }
        guard process.terminationStatus == 0, let image = NSImage(contentsOf: url) else { throw DeliveryError.captureFailed }
        return image
    }
}

enum ContextPayload {
    case image(NSImage)
    case file(URL)
    case text(String)

    var isText: Bool {
        if case .text = self { return true }
        return false
    }

    static func read(from pasteboard: NSPasteboard) -> ContextPayload? {
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], let url = urls.first {
            return .file(url)
        }

        if let images = pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage],
           let image = images.first {
            return .image(image)
        }

        if let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return .text(text)
        }
        return nil
    }
}

@MainActor
enum ChatGPTDelivery {
    static func send(image: NSImage, settings: SettingsStore) async throws {
        try await send(payload: .image(image), settings: settings, includePrompt: true)
    }

    static func send(payload: ContextPayload, settings: SettingsStore, includePrompt: Bool) async throws {
        guard AXIsProcessTrusted() else {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
            throw DeliveryError.accessibilityRequired
        }
        let workspace = NSWorkspace.shared
        let identifiers = ["com.openai.codex", "com.openai.chat", "com.openai.ChatGPT"]
        let running = workspace.runningApplications.first { app in
            app.bundleIdentifier.map(identifiers.contains) ?? false
        }
        let app: NSRunningApplication
        if let running {
            app = running
        } else if let url = identifiers.compactMap({ workspace.urlForApplication(withBundleIdentifier: $0) }).first {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            app = try await workspace.openApplication(at: url, configuration: configuration)
        } else {
            throw DeliveryError.chatGPTNotInstalled
        }

        app.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
        try await pause(700)
        if settings.destination == .newChat {
            postKey(UInt16(kVK_ANSI_N), flags: .maskCommand)
            try await pause(650)
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch payload {
        case .image(let image):
            pasteboard.writeObjects([image])
        case .file(let url):
            pasteboard.writeObjects([url as NSURL])
        case .text(let text):
            pasteboard.setString(text, forType: .string)
        }
        postKey(UInt16(kVK_ANSI_V), flags: .maskCommand)
        try await pause(900)

        let prompt = settings.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if includePrompt && !prompt.isEmpty {
            pasteboard.clearContents()
            pasteboard.setString(prompt, forType: .string)
            postKey(UInt16(kVK_ANSI_V), flags: .maskCommand)
            try await pause(250)
        }
        if settings.autoSend { postKey(UInt16(kVK_Return), flags: []) }
    }

    private static func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private static func pause(_ milliseconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: milliseconds * 1_000_000)
    }
}

struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    var body: some View {
        Form {
            Section("Destination") {
                Picker("Send screenshots to", selection: $store.destinationRaw) {
                    ForEach(Destination.allCases) { Text($0.label).tag($0.rawValue) }
                }.pickerStyle(.radioGroup)
                Text("For the current-chat option, open the desired conversation in ChatGPT before using the shortcut.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Keyboard shortcut") {
                Picker("Shortcut", selection: $store.shortcutRaw) {
                    ForEach(ShortcutChoice.allCases) { Text($0.label).tag($0.rawValue) }
                }
            }
            Section("Message") {
                TextField("Prompt", text: $store.prompt, axis: .vertical).lineLimit(2...4)
                Toggle("Send automatically", isOn: $store.autoSend)
                Text("Turn this off to review the screenshot before sending.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("The first capture requires Accessibility permission. macOS may also ask for Screen Recording access.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(8)
        .frame(minWidth: 500, minHeight: 410)
    }
}

@main
enum ScreenshotToChatGPTApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
