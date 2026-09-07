import SwiftUI
import PostfrauCore

/// Query parameters, mirrored two-way with the URL field.
struct ParamsTab: View {
    @Environment(AppState.self) private var state
    @Bindable var tab: RequestTab

    var body: some View {
        KeyValueEditor(
            rows: $tab.draft.params,
            keyPrompt: "Parameter",
            valuePrompt: "Value",
            onChange: {
                tab.paramsEdited()
                state.draftChanged(tab)
            })
        .accessibilityLabel("Query parameters")
    }
}
