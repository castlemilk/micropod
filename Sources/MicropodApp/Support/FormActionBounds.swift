import SwiftUI

/// Bounds of the actual primary controls, available to a host that wants to
/// verify an action stays reachable while its form scrolls or resizes.
struct FormActionBounds: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] { [:] }

    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

extension View {
    func formActionBounds(_ identifier: String) -> some View {
        anchorPreference(key: FormActionBounds.self, value: .bounds) { [identifier: $0] }
    }
}
