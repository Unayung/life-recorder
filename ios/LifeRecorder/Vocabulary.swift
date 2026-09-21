import SwiftUI

/// The glossary that fixes names and technical terms before transcription. It lives on the
/// desktop, so an edit made here is sent back and applies to the next clip.
struct VocabularyDocument: Codable {
    let text: String
    let updated: String
}

/// The file as the phone edits it: Markdown tables become rows, everything else is kept
/// exactly as written, so editing a name never disturbs the rest of the file.
struct Glossary {
    struct Row: Identifiable {
        let id: Int  // The line it came from.
        var cells: [String]
    }

    struct Section: Identifiable {
        let id: Int  // The heading's line.
        let title: String
        let columns: [String]
        let rows: [Row]
        let insertAt: Int  // Where a new row goes.
        let bodyRange: Range<Int>  // The lines below the heading, for sections without a table.
        var hasTable: Bool { !columns.isEmpty }
    }

    private var lines: [String]

    init(_ text: String) {
        lines = text.components(separatedBy: .newlines)
    }

    var text: String { lines.joined(separator: "\n") }

    var sections: [Section] {
        var sections: [Section] = []
        var heading: (line: Int, title: String)?
        var columns: [String] = []
        var rows: [Row] = []
        var insertAt = 0
        var bodyStart = 0

        func close(before end: Int) {
            guard let heading else { return }
            sections.append(Section(id: heading.line, title: heading.title, columns: columns, rows: rows,
                                    insertAt: insertAt == 0 ? end : insertAt,
                                    bodyRange: bodyStart..<max(bodyStart, end)))
        }

        for (index, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                close(before: index)
                heading = (index, line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces))
                columns = []
                rows = []
                insertAt = 0
                bodyStart = index + 1
                continue
            }
            guard line.hasPrefix("|") else { continue }
            let cells = line.split(separator: "|", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if cells.isEmpty || cells.allSatisfy({ $0.allSatisfy { $0 == "-" || $0 == ":" } }) { continue }
            if columns.isEmpty { columns = cells } else { rows.append(Row(id: index, cells: cells)) }
            insertAt = index + 1
        }
        close(before: lines.count)
        return sections
    }

    private func render(_ cells: [String], columns: Int) -> String {
        var cells = cells.map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "|", with: "/") }
        while cells.count < columns { cells.append("") }
        return "| " + cells.prefix(columns).joined(separator: " | ") + " |"
    }

    mutating func update(_ row: Row, columns: Int) {
        guard lines.indices.contains(row.id) else { return }
        lines[row.id] = render(row.cells, columns: columns)
    }

    mutating func add(_ cells: [String], to section: Section) {
        lines.insert(render(cells, columns: section.columns.count), at: min(section.insertAt, lines.count))
    }

    mutating func remove(_ row: Row) {
        guard lines.indices.contains(row.id) else { return }
        lines.remove(at: row.id)
    }

    func body(of section: Section) -> String {
        lines[section.bodyRange].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    mutating func replaceBody(of section: Section, with text: String) {
        lines.replaceSubrange(section.bodyRange, with: [""] + text.components(separatedBy: .newlines) + [""])
    }
}

@MainActor
final class VocabularyStore: ObservableObject {
    static let shared = VocabularyStore()

    @Published var glossary = Glossary("")
    @Published private(set) var status = ""
    @Published private(set) var busy = false
    @Published private(set) var failed = false
    /// The desktop's version when it changed under us; the editor asks which one to keep.
    @Published var conflict: VocabularyDocument?

    private var updated: String?
    private let cache: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("vocabulary.md")
    }()

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        return URLSession(configuration: config, delegate: PinnedTransport.shared, delegateQueue: nil)
    }()

    private init() {
        glossary = Glossary((try? String(contentsOf: cache, encoding: .utf8)) ?? "")
    }

    func load() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            adopt(try await send("GET", body: nil))
            status = ""
            failed = false
        } catch {
            // The last copy is still worth showing; an edit can wait for the desktop.
            failed = true
            status = glossary.text.isEmpty ? "Could not reach your desktop." : "Showing the last saved copy."
        }
    }

    /// Send the file as it now stands. `force` replaces whatever is there, for when the desktop changed too.
    func save(force: Bool = false) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let edited = glossary.text
        do {
            let document = try await send("PUT", body: ["text": edited, "updated": force ? nil : updated])
            updated = document.updated
            write(edited)  // Keep the edit, not the copy the desktop echoed back.
            conflict = nil
            failed = false
            status = "Saved. The next clip uses it."
        } catch VocabularyError.changedOnDesktop(let theirs) {
            conflict = theirs
            failed = true
            status = "This changed on your desktop while you were editing."
        } catch {
            write(edited)
            failed = true
            status = "Not saved yet. Your edit is kept here; open this again when your desktop is reachable."
        }
    }

    func keepTheirs() {
        guard let conflict else { return }
        adopt(conflict)
        self.conflict = nil
        status = "Using the desktop's version."
    }

    private func adopt(_ document: VocabularyDocument) {
        glossary = Glossary(document.text)
        updated = document.updated
        write(document.text)
    }

    private func write(_ text: String) {
        try? text.write(to: cache, atomically: true, encoding: .utf8)
    }

    private func send(_ method: String, body: [String: String?]?) async throws -> VocabularyDocument {
        guard let settings = ReceiverSettings.load() else { throw URLError(.userAuthenticationRequired) }
        var request = URLRequest(url: settings.baseURL.appendingPathComponent("v1/vocabulary"))
        request.httpMethod = method
        request.setValue("Bearer " + settings.token, forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body.compactMapValues { $0 })
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 409 {
            throw VocabularyError.changedOnDesktop(try JSONDecoder().decode(VocabularyDocument.self, from: data))
        }
        guard status == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(VocabularyDocument.self, from: data)
    }
}

enum VocabularyError: Error {
    case changedOnDesktop(VocabularyDocument)
}

struct VocabularyView: View {
    @ObservedObject private var store = VocabularyStore.shared
    @State private var editingText = false

    var body: some View {
        List {
            ForEach(store.glossary.sections) { section in
                NavigationLink {
                    if section.hasTable { GlossarySectionView(section: section) }
                    else { GlossaryNotesView(section: section) }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(section.title)
                        Text(section.hasTable ? "\(section.rows.count) entries" : "Notes")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Text("These names are given to the transcriber before every clip, so a fix here changes how the next one comes out.")
                    .font(.caption).foregroundStyle(.secondary)
                if !store.status.isEmpty {
                    Text(store.status).font(.footnote)
                        .foregroundStyle(store.failed ? Color.orange : Color.secondary)
                }
            }
        }
        .navigationTitle("Names and terms")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if store.busy { ProgressView() }
                Menu {
                    Button("Reload from desktop", systemImage: "arrow.clockwise") {
                        Task { await store.load() }
                    }
                    Button("Edit as text", systemImage: "doc.plaintext") { editingText = true }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(isPresented: $editingText) { GlossaryTextView() }
        .task { await store.load() }
        .alert("Changed on your desktop", isPresented: Binding(get: { store.conflict != nil },
                                                               set: { if !$0 { store.conflict = nil } })) {
            Button("Keep mine") { Task { await store.save(force: true) } }
            Button("Use the desktop's", role: .cancel) { store.keepTheirs() }
        } message: {
            Text("The glossary changed while this was open. Keeping yours replaces theirs.")
        }
    }
}

/// One table: its rows, each opening a small form.
struct GlossarySectionView: View {
    @ObservedObject private var store = VocabularyStore.shared
    let section: Glossary.Section
    @State private var adding = false

    private var current: Glossary.Section {
        store.glossary.sections.first { $0.title == section.title } ?? section
    }

    var body: some View {
        List {
            ForEach(current.rows) { row in
                NavigationLink {
                    GlossaryRowView(section: current, row: row)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.cells.first ?? "").font(.body)
                        let rest = row.cells.dropFirst().filter { !$0.isEmpty }.joined(separator: " · ")
                        if !rest.isEmpty {
                            Text(rest).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .onDelete { offsets in
                for row in offsets.map({ current.rows[$0] }) { store.glossary.remove(row) }
                Task { await store.save() }
            }
        }
        .navigationTitle(current.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("Add", systemImage: "plus") { adding = true }
        }
        .sheet(isPresented: $adding) {
            NavigationStack { GlossaryRowView(section: current, row: nil) }
        }
    }
}

/// Add or change one entry. Saving sends the whole file, so the desktop stays in step.
struct GlossaryRowView: View {
    @ObservedObject private var store = VocabularyStore.shared
    @Environment(\.dismiss) private var dismiss
    let section: Glossary.Section
    let row: Glossary.Row?
    @State private var cells: [String] = []

    var body: some View {
        Form {
            ForEach(Array(section.columns.enumerated()), id: \.offset) { index, column in
                Section(column) {
                    TextField(column, text: Binding(
                        get: { index < cells.count ? cells[index] : "" },
                        set: { value in
                            while cells.count <= index { cells.append("") }
                            cells[index] = value
                        }), axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            if section.columns.count > 1 {
                Text("Separate several mishearings with commas.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(row == nil ? "New entry" : (row?.cells.first ?? ""))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    if var row {
                        row.cells = cells
                        store.glossary.update(row, columns: section.columns.count)
                    } else {
                        store.glossary.add(cells, to: section)
                    }
                    Task { await store.save() }
                    dismiss()
                }
                .disabled(cells.first?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
            }
            if row == nil {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .task { cells = row?.cells ?? Array(repeating: "", count: section.columns.count) }
    }
}

/// Sections that are prose or a comma list, such as the prompt itself.
struct GlossaryNotesView: View {
    @ObservedObject private var store = VocabularyStore.shared
    let section: Glossary.Section
    @State private var text = ""

    var body: some View {
        TextEditor(text: $text)
            .font(.system(.body, design: .monospaced))
            .padding(.horizontal, 12)
            .navigationTitle(section.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Save") {
                    store.glossary.replaceBody(of: section, with: text)
                    Task { await store.save() }
                }
            }
            .task { text = store.glossary.body(of: section) }
    }
}

/// The whole file, for anything the forms don't cover.
struct GlossaryTextView: View {
    @ObservedObject private var store = VocabularyStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .font(.system(.caption, design: .monospaced))
                .padding(.horizontal, 12)
                .navigationTitle("Glossary file")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            store.glossary = Glossary(text)
                            Task { await store.save() }
                            dismiss()
                        }
                    }
                }
                .task { text = store.glossary.text }
        }
    }
}
