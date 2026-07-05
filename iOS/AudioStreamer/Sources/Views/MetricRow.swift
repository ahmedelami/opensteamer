import SwiftUI

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
