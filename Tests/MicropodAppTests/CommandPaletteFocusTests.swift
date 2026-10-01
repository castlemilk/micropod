import AppKit
import SwiftUI
import XCTest

@testable import MicropodApp

final class CommandPaletteFocusTests: XCTestCase {
    @MainActor
    func testPresentedPaletteTakesFieldEditorFocusFromUnderlyingSearch() async throws {
        let fixture = try AppTestCLI.makeMock()
        defer { AppTestCLI.cleanUp(fixture) }
        let store = makeRunningStore(client: fixture.client)
        defer { store.stopPollers() }

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
        let previousEditor = try XCTUnwrap(underlyingSearch.currentEditor())
        XCTAssertTrue(window.firstResponder === previousEditor)

        store.showCommandPalette = true
        let hosting = NSHostingView(
            rootView: CommandPaletteView(store: store)
                .environment(\.locale, Locale(identifier: "en")))
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: size)
        root.addSubview(hosting)
        hosting.layoutSubtreeIfNeeded()

        // The native search field must become first responder after insertion;
        // an immediate SwiftUI onAppear focus request can leave focus underneath.
        try await waitUntil(timeout: .milliseconds(800)) {
            guard let search = self.editableTextFields(in: hosting).first,
                let editor = search.currentEditor()
            else { return false }
            return window.firstResponder === editor && underlyingSearch.currentEditor() == nil
        }

        let fields = editableTextFields(in: hosting)
        XCTAssertEqual(fields.count, 1, "The palette has one editable search field")
        let paletteSearch = try XCTUnwrap(fields.first)
        let paletteEditor = try XCTUnwrap(paletteSearch.currentEditor())
        XCTAssertTrue(window.firstResponder === paletteEditor, "Typing must go to the palette's field editor")
        XCTAssertNil(underlyingSearch.currentEditor(), "The previous page search must relinquish editing")
    }

    @MainActor
    private func editableTextFields(in view: NSView) -> [NSTextField] {
        var fields: [NSTextField] = []
        if let field = view as? NSTextField, field.isEditable { fields.append(field) }
        for child in view.subviews { fields.append(contentsOf: editableTextFields(in: child)) }
        return fields
    }
}
