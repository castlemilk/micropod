import AppKit
import SwiftUI
import XCTest

@testable import MicropodApp

final class CommandPaletteFocusTests: XCTestCase {
    @MainActor
    func testPresentedPaletteTakesFieldEditorFocusFromUnderlyingSearch() async throws {
        var phase = "fixture"
        defer { print("CommandPaletteFocusTests finalPhase=\(phase)") }
        let fixture = try AppTestCLI.makeMock()
        defer { AppTestCLI.cleanUp(fixture) }
        let store = makeRunningStore(client: fixture.client)
        defer { store.stopPollers() }

        phase = "native-window"
        _ = NSApplication.shared
        let size = NSSize(width: 640, height: 460)
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        let underlyingSearch = NSTextField(frame: NSRect(x: 20, y: 400, width: 300, height: 24))
        underlyingSearch.placeholderString = "Underlying search"
        root.addSubview(underlyingSearch)

        let window = NSWindow(
            contentRect: root.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer {
            store.showCommandPalette = false
            window.orderOut(nil)
            window.close()
        }

        // Command-line XCTest verifies the window-local responder handoff;
        // packaged foreground keyboard behavior is exercised separately.
        window.orderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(underlyingSearch))
        phase = "underlying-editor"
        let previousEditor = try XCTUnwrap(underlyingSearch.currentEditor())
        XCTAssertTrue(window.firstResponder === previousEditor)

        phase = "palette-mount"
        store.showCommandPalette = true
        let lifecycle = PaletteLifecycle()
        let hosting = NSHostingView(
            rootView: PaletteFocusFixture(store: store, lifecycle: lifecycle))
        defer {
            window.makeFirstResponder(nil)
            hosting.removeFromSuperview()
            window.contentView = nil
        }
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: size)
        root.addSubview(hosting)
        hosting.layoutSubtreeIfNeeded()

        func dismissPalette() async throws {
            window.makeFirstResponder(underlyingSearch)
            store.showCommandPalette = false
            hosting.layoutSubtreeIfNeeded()
            // Retain the window and host until SwiftUI acknowledges removal.
            try await waitUntil(timeout: .milliseconds(800)) {
                lifecycle.disappeared && self.editableTextFields(in: hosting).isEmpty
            }
        }

        do {
            // The native search field must become first responder after insertion;
            // an immediate SwiftUI onAppear focus request can leave focus underneath.
            phase = "focus-poll"
            try await waitUntil(timeout: .milliseconds(800)) {
                guard let search = self.editableTextFields(in: hosting).first,
                    let editor = search.currentEditor()
                else { return false }
                return window.firstResponder === editor && underlyingSearch.currentEditor() == nil
            }

            phase = "focus-assertions"
            let fields = editableTextFields(in: hosting)
            XCTAssertEqual(fields.count, 1, "The palette has one editable search field")
            let paletteSearch = try XCTUnwrap(fields.first)
            let paletteEditor = try XCTUnwrap(paletteSearch.currentEditor())
            XCTAssertTrue(window.firstResponder === paletteEditor, "Typing must go to the palette's field editor")
            XCTAssertNil(underlyingSearch.currentEditor(), "The previous page search must relinquish editing")
            phase = "palette-dismiss"
            try await dismissPalette()
            phase = "complete"
        } catch {
            let failurePhase = phase
            try? await dismissPalette()
            phase = failurePhase
            throw error
        }
    }

    @MainActor
    private func editableTextFields(in view: NSView) -> [NSTextField] {
        var fields: [NSTextField] = []
        if let field = view as? NSTextField, field.isEditable { fields.append(field) }
        for child in view.subviews { fields.append(contentsOf: editableTextFields(in: child)) }
        return fields
    }
}

@MainActor
private final class PaletteLifecycle {
    var disappeared = false
}

private struct PaletteFocusFixture: View {
    @Bindable var store: AppStore
    let lifecycle: PaletteLifecycle

    var body: some View {
        if store.showCommandPalette {
            CommandPaletteView(store: store)
                .environment(\.locale, Locale(identifier: "en"))
                .onDisappear { lifecycle.disappeared = true }
        }
    }
}
