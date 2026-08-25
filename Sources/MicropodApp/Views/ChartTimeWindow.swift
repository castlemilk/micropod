import SwiftUI

/// Time-window selector shared by the dashboard and per-container charts.
enum ChartTimeWindow: String, CaseIterable, Identifiable {
    case fiveMinutes = "5m"
    case fifteenMinutes = "15m"
    case oneHour = "60m"
    case threeHours = "3h"

    var id: String { rawValue }

    var duration: TimeInterval {
        switch self {
        case .fiveMinutes: 5 * 60
        case .fifteenMinutes: 15 * 60
        case .oneHour: 60 * 60
        case .threeHours: 3 * 60 * 60
        }
    }
}

/// Segmented 5m | 15m | 60m | 3h picker (HIG segmented control).
struct ChartTimeWindowPicker: View {
    @Binding var window: ChartTimeWindow

    var body: some View {
        Picker("Time window", selection: $window) {
            ForEach(ChartTimeWindow.allCases) { w in
                Text(w.rawValue).tag(w)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 220)
        .help("Chart time window")
        .accessibilityLabel("Chart time window")
    }
}

extension Array where Element == ResourceSample {
    /// Samples within the given window, most recent last.
    func within(_ window: ChartTimeWindow) -> [ResourceSample] {
        let cutoff = Date().addingTimeInterval(-window.duration)
        return filter { $0.timestamp >= cutoff }
    }
}

/// Evenly-spaced decimation capped at `maxPoints`, always including the
/// newest item. Keeps chart rendering O(360) no matter how deep the store is.
func downsample<T>(_ items: [T], maxPoints: Int) -> [T] {
    guard items.count > maxPoints, maxPoints > 0 else { return items }
    let step = (items.count + maxPoints - 1) / maxPoints
    var result: [T] = []
    result.reserveCapacity(maxPoints + 1)
    var index = 0
    while index < items.count {
        result.append(items[index])
        index += step
    }
    if (items.count - 1) % step != 0 {
        result.append(items[items.count - 1])
    }
    return result
}
