import SwiftUI

@main struct MyApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            ContentView(model: model)
        } label: {
            Image(systemName: model.menuBarIcon)
            if !model.menuBarTitle.isEmpty {
                Text(model.menuBarTitle)
                    .monospacedDigit()
            }
        }
        .menuBarExtraStyle(.window)
    }
}
