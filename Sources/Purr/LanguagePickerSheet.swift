import SwiftUI

// Conformed by WhisperLanguage and ParakeetLanguage so both share one picker.
// `code` empty = the list's sentinel entry (Auto-detect / English).
protocol LanguageOption: Identifiable, Hashable where ID == String {
    var code: String { get }
    var name: String { get }
}

// Modal sheet for picking a language from a long list (Whisper's 100 translation
// source languages, Parakeet v3's meeting languages). A compact settings row can't
// host a list that size, so a dedicated picker owns the search interaction - the
// same shape macOS System Settings uses for Language & Region and Input Sources.
struct LanguagePickerSheet<Option: LanguageOption>: View {
    let title: String
    @Binding var selection: String
    let allLanguages: [Option]
    let matching: (String) -> [Option]
    let onClose: () -> Void

    @State private var query: String = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            searchField
            Divider()
            languageList
        }
        .frame(width: 380, height: 460)
        .onAppear { searchFocused = true }
    }

    private var header: some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            Button("Done") { onClose() }
                .keyboardShortcut(.defaultAction)
        }
        .padding()
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear search")
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var languageList: some View {
        if items.isEmpty {
            VStack {
                Spacer()
                Text("No language matches \"\(query)\".")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { language in
                        Button {
                            selection = language.code
                            onClose()
                        } label: {
                            HStack {
                                Text(language.name)
                                Spacer()
                                if language.code == selection {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading)
                    }
                }
            }
        }
    }

    // An empty search leads with the list's sentinel entry (Auto-detect for Whisper,
    // English for Parakeet) so it's as findable as any specific language. Searching
    // defers to `matching`, which deliberately omits the sentinel; clearing the
    // search restores it.
    private var items: [Option] {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            return allLanguages
        }
        return matching(query)
    }
}
