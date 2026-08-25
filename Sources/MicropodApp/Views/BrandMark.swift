import AppKit
import SwiftUI

/// Micropod's brand mark (BrandBrain-generated): a small rounded tile used
/// as the one restrained brand moment in the app.
struct BrandMark: View {
    var size: CGFloat = 28

    var body: some View {
        if let url = Bundle.module.url(forResource: "micropod-mark", withExtension: "png"),
            let image = NSImage(contentsOf: url)
        {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: size * 0.6))
                .foregroundStyle(.tint)
                .frame(width: size, height: size)
        }
    }
}
