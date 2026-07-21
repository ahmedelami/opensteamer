import SwiftUI

/// Consistent diagnostics row with monospaced digits to prevent metric updates from shifting.
struct MetricRow: View {
    let title: String
    let value: String

    var body: some View {
        LabeledContent {
            Text(value)
                .monospacedDigit()
        } label: {
            Text(title)
        }
    }
}
