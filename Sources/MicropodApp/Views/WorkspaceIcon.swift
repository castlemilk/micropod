import AppKit
import SwiftUI

/// Tintable vector pictograms from the design kit. Decoded once, never per row.
struct WorkspaceIcon: View {
    let name: String
    var size: CGFloat = 18
    var fallback: String = "square"

    var body: some View {
        Group {
            if let image = WorkspaceIconImages.image(named: name) {
                Image(nsImage: image).resizable().renderingMode(.template)
            } else {
                Image(systemName: fallback).resizable().scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

@MainActor
private enum WorkspaceIconImages {
    private static var images: [String: NSImage] = [:]
    private static var missing: Set<String> = []

    static func image(named name: String) -> NSImage? {
        if let image = images[name] { return image }
        guard !missing.contains(name) else { return nil }
        guard let url = Bundle.micropodResources.url(forResource: name, withExtension: "svg", subdirectory: "uplift"),
            let image = NSImage(contentsOf: url)
        else {
            missing.insert(name)
            return nil
        }
        image.isTemplate = true
        images[name] = image
        return image
    }
}
