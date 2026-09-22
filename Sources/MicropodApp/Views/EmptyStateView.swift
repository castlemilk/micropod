import SwiftUI

/// A branded empty state that renders a BrandBrain illustration when present
/// (Resources/brandbrain/<imageName>.png) and falls back to an SF Symbol.
/// HIG: every empty surface teaches — an optional next action is prominent.
struct EmptyStateView: View {
    let title: String
    let description: String
    var imageName: String?
    var symbol: String = "square.dashed"
    var actionTitle: String?
    var action: (() -> Void)?
    var accent: Color = Color.accentColor

    var body: some View {
        VStack(spacing: Tokens.Spacing.md) {
            illustration
                .frame(width: 120, height: 120)
            Text(title)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(description)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .padding(.top, Tokens.Spacing.xs)
            }
        }
        .padding(Tokens.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var illustration: some View {
        if let imageName, let uiImage = brandbrainImage(imageName) {
            // The assets are white-matte line art — present them on a rounded
            // white canvas so they read as a deliberate tile in dark mode too.
            Image(nsImage: uiImage)
                .resizable()
                .scaledToFit()
                .padding(Tokens.Spacing.md)
                .background(
                    Color.white,
                    in: RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous)
                        .stroke(Color.black.opacity(0.10), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.10), radius: 8, y: 3)
                .accessibilityLabel(title)
        } else {
            Image(systemName: symbol)
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(accent.opacity(0.85))
                .accessibilityHidden(true)
        }
    }

    /// Looks up a BrandBrain asset (cached); falls back to nil (SF symbol).
    private func brandbrainImage(_ name: String) -> NSImage? {
        EmptyStateArtwork.image(named: name)
    }

    /// Small inline brand illustration (headers, onboarding cards) presented
    /// as a rounded white chip so the matte art stays crisp on any surface.
    static func brandMark(_ name: String, size: CGFloat, symbol: String = "shippingbox") -> some View {
        Group {
            if let uiImage = EmptyStateArtwork.image(named: name) {
                Image(nsImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.14)
                    .frame(width: size, height: size)
                    .background(
                        Color.white,
                        in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                            .stroke(Color.black.opacity(0.10), lineWidth: 1)
                    )
            } else if name == EmptyStateArtwork.dashboardHero {
                BrandMark(size: size)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.55, weight: .light))
                    .foregroundStyle(Color.accentColor.opacity(0.85))
            }
        }
    }
}

/// Empty-state illustration names per Micropod tab, so the BrandBrain asset
/// set (Resources/brandbrain/*.png) lights up without code changes.
enum EmptyStateArtwork {
    static let containers = "containers-empty"
    static let images = "images-empty"
    static let volumes = "volumes-empty"
    static let networks = "networks-empty"
    static let registries = "registries-empty"
    static let build = "build-empty"
    static let compose = "compose-empty"
    static let environments = "environments-empty"
    static let storage = "storage-empty"
    static let dashboardHero = "dashboard-hero"
    static let onboardingRuntime = "onboarding-runtime"
    static let onboardingKernel = "onboarding-kernel"
    static let onboardingPull = "onboarding-pull"
    static let onboardingRun = "onboarding-run"

    private static let lock = NSLock()
    private nonisolated(unsafe) static var cache: [String: NSImage?] = [:]

    /// Resolves a BrandBrain illustration from the packaged resources.
    /// Decoded once and cached — headers re-render on every store change and
    /// the uncached path did disk I/O + PNG decode per render.
    static func image(named name: String) -> NSImage? {
        lock.lock()
        if let cached = cache[name] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        var resolved: NSImage?
        for bundle in [Bundle.micropodResources, Bundle.main] {
            for ext in ["png", "svg"] {
                if let url = bundle.url(forResource: name, withExtension: ext, subdirectory: "brandbrain"),
                    let image = NSImage(contentsOf: url)
                {
                    resolved = image
                    break
                }
            }
            if resolved != nil { break }
        }
        lock.lock()
        cache[name] = resolved
        lock.unlock()
        return resolved
    }
}
