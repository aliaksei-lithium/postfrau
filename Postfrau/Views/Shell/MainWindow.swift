import SwiftUI

struct MainWindow: View {
    @State private var sidebarSelection: String? = "placeholder"

    var body: some View {
        NavigationSplitView {
            List(selection: $sidebarSelection) {
                Section("Collections") {
                    Label("Postfrau", systemImage: "shippingbox")
                        .tag("placeholder")
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 420)
        } detail: {
            VSplitView {
                requestPlaceholder
                responsePlaceholder
            }
        }
        .toolbar {
            ToolbarSpacer(.flexible)
            ToolbarItem {
                Button {
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .navigationTitle("Postfrau")
    }

    private var requestPlaceholder: some View {
        VStack {
            Spacer()
            Text("Postfrau")
                .font(.largeTitle.weight(.semibold))
            Text("Request composer goes here.")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    private var responsePlaceholder: some View {
        VStack {
            Spacer()
            Text("No response yet — ⌘↩ to send.")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

#Preview {
    MainWindow()
}
