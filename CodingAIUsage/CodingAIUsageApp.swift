import SwiftUI

@main
struct CodingAIUsageApp: App {
    @StateObject private var viewModel = UsageViewModel()

    var body: some Scene {
        MenuBarExtra {
            UsageDetailView(viewModel: viewModel)
        } label: {
            MenuBarLabel(viewModel: viewModel)
        }
        .menuBarExtraStyle(.window)
    }
}
