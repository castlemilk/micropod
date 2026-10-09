// Compile with Support/MainWindowPresenter.swift. This isolated app uses the
// production SwiftUI scene and presenter, with no AppStore/runtime/helpers.
import AppKit
import SwiftUI

@main
struct MainWindowSmokeApp: App {
    @NSApplicationDelegateAdaptor(MicropodApplicationDelegate.self) private var delegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MainWindowScene(title: "Micropod Window QA") {
            VStack(spacing: 20) {
                Image(systemName: "macwindow").font(.system(size: 48))
                Text("Single main window").font(.largeTitle)
                Text("Isolated native lifecycle regression · no runtime or job actions")
            }
            .padding(40)
            .frame(minWidth: 720, minHeight: 460)
            .task { await WindowSmoke.shared.run() }
        }
        .defaultSize(width: 760, height: 500)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Open Main Window QA") {
                    MainWindowPresenter.shared.show { openWindow(id: MainWindowPresenter.sceneID) }
                }
            }
        }
        MenuBarExtra("Window QA", systemImage: "macwindow") {
            Text("Isolated Micropod window regression")
        }
    }
}

@MainActor
private final class WindowSmoke {
    static let shared = WindowSmoke()
    private var started = false
    private var records: [[String: Any]] = []
    private let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MICROPOD_WINDOW_QA_DIR"]!)

    private enum Failure: Error {
        case condition(String)
        case missingMenu, missingImage
    }

    private var mainWindows: [NSWindow] {
        NSApplication.shared.windows.filter {
            $0.title == "Micropod Window QA" && ($0.isVisible || $0.isMiniaturized)
        }
    }

    func run() async {
        guard !started else { return }
        started = true
        do {
            try await until("initial main window") { self.mainWindows.count == 1 }
            let first = mainWindows[0]
            record("initial", window: first)
            try capture(first, name: "initial")
            for _ in 0..<20 { try clickOpen() }
            try await until("repeated menu Open") { self.mainWindows.count == 1 && first.isKeyWindow }
            require(mainWindows[0] === first, "repeated Open replaced the window")
            record("repeated-menu-open", window: first)

            first.miniaturize(nil)
            try await until("minimization") { first.isMiniaturized }
            try clickOpen()
            try await until("restore minimized window") { !first.isMiniaturized && first.isKeyWindow }
            require(mainWindows.count == 1 && mainWindows[0] === first, "minimized Open duplicated the window")
            record("minimized-open", window: first)
            try capture(first, name: "restored")

            let auxiliary = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 220),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            auxiliary.title = "Window QA auxiliary"
            auxiliary.isReleasedWhenClosed = false
            auxiliary.makeKeyAndOrderFront(nil)
            let delegate = MicropodApplicationDelegate()
            require(
                !delegate.applicationShouldHandleReopen(.shared, hasVisibleWindows: true), "Dock reopen was not handled"
            )
            try await until("Dock activation with auxiliary window") { first.isKeyWindow }
            require(mainWindows.count == 1 && mainWindows[0] === first, "Dock activation duplicated the window")
            record("dock-with-auxiliary", window: first)
            auxiliary.close()

            first.close()
            try await until("closed main window") { self.mainWindows.isEmpty }
            require(
                !delegate.applicationShouldHandleReopen(.shared, hasVisibleWindows: false),
                "closed-window reopen was not handled")
            try await until("reopened main window") { self.mainWindows.count == 1 }
            let reopened = mainWindows[0]
            for _ in 0..<20 { try clickOpen() }
            try await until("repeated Open after close") { self.mainWindows.count == 1 && reopened.isKeyWindow }
            record("close-and-reopen", window: reopened)
            try capture(reopened, name: "reopened")

            // The supported Launch Services route must reuse this app process.
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = false
            configuration.activates = true
            let application = try await NSWorkspace.shared.openApplication(
                at: Bundle.main.bundleURL, configuration: configuration)
            require(application.processIdentifier == getpid(), "already-running Open started another process")
            try await until("already-running application Open") { self.mainWindows.count == 1 }
            record("already-running-open", window: mainWindows[0])
            try writeResult(passed: true, error: nil)
            exit(0)
        } catch {
            try? writeResult(passed: false, error: String(describing: error))
            FileHandle.standardError.write(Data("Window smoke failed: \(error)\n".utf8))
            exit(1)
        }
    }

    private func until(_ name: String, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            if Date() >= deadline { throw Failure.condition(name) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func require(_ condition: Bool, _ message: String) {
        guard condition else {
            try? writeResult(passed: false, error: message)
            FileHandle.standardError.write(Data("Window smoke failed: \(message)\n".utf8))
            exit(1)
        }
    }

    private func clickOpen() throws {
        func find(_ menu: NSMenu) -> (NSMenu, Int)? {
            for (index, item) in menu.items.enumerated() {
                if item.title == "Open Main Window QA" { return (menu, index) }
                if let submenu = item.submenu, let match = find(submenu) { return match }
            }
            return nil
        }
        guard let menu = NSApplication.shared.mainMenu, let (parent, index) = find(menu) else {
            throw Failure.missingMenu
        }
        parent.performActionForItem(at: index)
    }

    private func record(_ phase: String, window: NSWindow) {
        records.append([
            "phase": phase, "mainWindows": mainWindows.count,
            "windowNumber": window.windowNumber, "miniaturized": window.isMiniaturized,
            "key": window.isKeyWindow, "process": getpid(),
        ])
    }

    private func capture(_ window: NSWindow, name: String) throws {
        guard let view = window.contentView,
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { throw Failure.missingImage }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw Failure.missingImage }
        try png.write(to: output.appendingPathComponent("\(name).png"))
    }

    private func writeResult(passed: Bool, error: String?) throws {
        var result: [String: Any] = [
            "passed": passed, "observations": records,
            "surface": "production MainWindowScene and presenter in isolated native app",
            "installedMicropodAcceptance": false,
            "runtimeOrJobActions": false,
        ]
        if let error { result["error"] = error }
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("result.json"))
    }
}
