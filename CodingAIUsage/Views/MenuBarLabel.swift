import SwiftUI

struct MenuBarLabel: View {
    @ObservedObject var viewModel: UsageViewModel

    var body: some View {
        Text(viewModel.menuBarPlainText)
            .font(.system(.caption2, design: .monospaced))
    }
}
