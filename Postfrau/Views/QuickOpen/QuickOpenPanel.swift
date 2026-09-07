import SwiftUI
import PostfrauCore

/// One thing ⌘K can jump to.
struct QuickOpenResult: Identifiable, Hashable {
    var id: UUID
    var method: HTTPMethod
    var name: String
    /// `Acme API / Users` — where it lives.
    var path: String
    var url: String
    /// Offsets into `searchText` the query matched, for bolding.
    var matchedOffsets: [Int]
    var searchText: String
}

/// The ⌘K fuzzy finder.
///
/// A floating panel over the window, which is exactly the case §5 reserves `.glassEffect()` for.
struct QuickOpenPanel: View {
    @Environment(AppState.self) private var state
    @Binding var isPresented: Bool

    @FocusState private var fieldFocused: Bool

    private var query: Binding<String> {
        Binding(get: { state.quickOpenQuery }, set: { state.quickOpenQuery = $0 })
    }

    private var selection: Int {
        get { state.quickOpenSelection }
        nonmutating set { state.quickOpenSelection = newValue }
    }

    private var results: [QuickOpenResult] {
        state.quickOpenResults(matching: state.quickOpenQuery)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Jump to a request…", text: query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                    .onSubmit(openSelection)
                    .accessibilityLabel("Quick open search")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            if results.isEmpty {
                Text(state.quickOpenQuery.isEmpty
                    ? "Start typing to find a request." : "No matches.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        // Not a `LazyVStack`: the list is capped at 60 rows, so laziness buys
                        // nothing, and a lazy stack here kept showing rows from the previous
                        // query — it realized the first row once and never refreshed it.
                        VStack(spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                                row(result, isSelected: index == selection)
                                    .id(index)
                                    .onTapGesture {
                                        selection = index
                                        openSelection()
                                    }
                            }
                        }
                    }
                    .frame(maxHeight: 320)
                    .onChange(of: selection) { _, index in
                        withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(index) }
                    }
                }
            }
        }
        .frame(width: 560)
        .background(.regularMaterial, in: .rect(cornerRadius: 12))
        .glassEffect(in: .rect(cornerRadius: 12))
        .defaultFocus($fieldFocused, true)
        // The panel opens over content that already holds focus, and SwiftUI does not hand it
        // over until the overlay has been laid out — so ask again on the next turn. A palette you
        // cannot type into the instant it appears is not worth having.
        .task {
            fieldFocused = true
            try? await Task.sleep(for: .milliseconds(60))
            fieldFocused = true
        }
        .onChange(of: state.quickOpenQuery) { selection = 0 }
        .onKeyPress(.downArrow) {
            selection = min(selection + 1, max(results.count - 1, 0))
            return .handled
        }
        .onKeyPress(.upArrow) {
            selection = max(selection - 1, 0)
            return .handled
        }
        .onKeyPress(.escape) {
            isPresented = false
            return .handled
        }
        // No container-level label here: one on a panel that contains an editable field replaces
        // the field's own label, which leaves VoiceOver announcing the panel and never the field.
        .accessibilityElement(children: .contain)
    }

    private func row(_ result: QuickOpenResult, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            MethodBadge(method: result.method).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                MatchedText(searchText: result.searchText, offsets: result.matchedOffsets, name: result.name)
                    .lineLimit(1)
                Text(result.path)
                    .font(.caption)
                    .foregroundStyle(isSelected
                        ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(result.url)
                .font(.caption.monospaced())
                .foregroundStyle(isSelected
                    ? AnyShapeStyle(.white.opacity(0.7)) : AnyShapeStyle(.tertiary))
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: 220, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor : .clear)
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(result.method.rawValue) \(result.name), in \(result.path)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func openSelection() {
        guard results.indices.contains(selection) else { return }
        state.openRequest(id: results[selection].id)
        isPresented = false
    }
}

/// A request's name with the matched characters bolded.
struct MatchedText: View {
    var searchText: String
    var offsets: [Int]
    var name: String

    var body: some View {
        // Only the name is shown; the offsets index the combined search text, so a match inside
        // the path or URL simply does not light anything up — which is the honest thing to show.
        let nameLength = name.utf16.count
        var attributed = AttributedString(name)
        for offset in offsets where offset < nameLength {
            guard let start = AttributedString.Index(
                    String.Index(utf16Offset: offset, in: name), within: attributed),
                  let end = AttributedString.Index(
                    String.Index(utf16Offset: offset + 1, in: name), within: attributed)
            else { continue }
            attributed[start..<end].inlinePresentationIntent = .stronglyEmphasized
        }
        return Text(attributed)
    }
}

extension AppState {
    /// Every request in the workspace, ranked against `query`.
    func quickOpenResults(matching query: String, limit: Int = 60) -> [QuickOpenResult] {
        var candidates: [QuickOpenResult] = []
        for collection in workspace.collections {
            for entry in collection.allRequests() {
                let folderNames = entry.folderIDs.compactMap { collection.folder(withID: $0)?.name }
                let path = ([collection.name] + folderNames).joined(separator: " / ")
                // Matching across name, path and URL together is what makes "acme users list"
                // find the right request.
                let searchText = "\(entry.request.name) \(path) \(entry.request.url)"
                candidates.append(QuickOpenResult(
                    id: entry.request.id,
                    method: entry.request.method,
                    name: entry.request.name,
                    path: path,
                    url: entry.request.url,
                    matchedOffsets: [],
                    searchText: searchText))
            }
        }

        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return Array(candidates.prefix(limit))
        }
        let ranked = FuzzyMatcher.rank(candidates, query: query) { $0.searchText }
        return ranked.prefix(limit).map { candidate, match in
            var result = candidate
            result.matchedOffsets = match.matchedOffsets
            return result
        }
    }
}
