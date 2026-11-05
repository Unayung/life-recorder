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

/// Fixing a name from what was read: which entry it belongs to, and teaching the file a new mishearing.
extension Glossary {
    struct Entry {
        let section: Section
        let row: Row
        var name: String { row.cells.first ?? "" }
    }

    /// The column listing what the transcriber writes instead, such as 常見誤轉.
    static func heardColumn(of section: Section) -> Int? {
        guard section.columns.count > 1 else { return nil }
        return section.columns.firstIndex {
            $0.contains("誤") || ["heard", "mishear", "sounds"].contains(where: $0.lowercased().contains)
        } ?? section.columns.count - 1
    }

    /// The first column that is neither the name nor the mishearings, such as 角色 or 說明.
    static func noteColumn(of section: Section) -> Int? {
        let heard = heardColumn(of: section)
        return section.columns.indices.dropFirst().first { $0 != heard }
    }

    static func mishearings(_ cell: String) -> [String] {
        cell.components(separatedBy: CharacterSet(charactersIn: ",，、"))
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(b.trimmingCharacters(in: .whitespaces)) == .orderedSame
    }

    /// The entry spelled exactly this way.
    func entry(named name: String) -> Entry? {
        for section in sections where section.hasTable {
            if let row = section.rows.first(where: { Self.same($0.cells.first ?? "", name) }) {
                return Entry(section: section, row: row)
            }
        }
        return nil
    }

    /// The entry this text is, or is a known mishearing of.
    func entry(matching text: String) -> Entry? {
        if let entry = entry(named: text) { return entry }
        for section in sections where section.hasTable {
            guard let column = Self.heardColumn(of: section) else { continue }
            if let row = section.rows.first(where: { row in
                column < row.cells.count && Self.mishearings(row.cells[column]).contains { Self.same($0, text) }
            }) { return Entry(section: section, row: row) }
        }
        return nil
    }

    /// Whether the file already knows that `heard` means `name`.
    func knows(heard: String, means name: String) -> Bool {
        guard let entry = entry(named: name) else { return false }
        guard !Self.same(heard, name) else { return true }
        guard let column = Self.heardColumn(of: entry.section), column < entry.row.cells.count else { return false }
        return Self.mishearings(entry.row.cells[column]).contains { Self.same($0, heard) }
    }

    /// Record that `heard` is how `name` gets transcribed: added to that name's entry when it has
    /// one, otherwise a new entry in `sectionTitle`. Returns whether the file changed.
    @discardableResult
    mutating func learn(heard: String, means name: String, note: String = "", in sectionTitle: String) -> Bool {
        let heard = heard.trimmingCharacters(in: .whitespaces)
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !knows(heard: heard, means: name) else { return false }
        if let entry = entry(named: name) {
            guard !heard.isEmpty, let column = Self.heardColumn(of: entry.section) else { return false }
            var row = entry.row
            while row.cells.count <= column { row.cells.append("") }
            row.cells[column] = (Self.mishearings(row.cells[column]) + [heard]).joined(separator: ", ")
            update(row, columns: entry.section.columns.count)
            return true
        }
        guard let section = sections.first(where: { $0.hasTable && $0.title == sectionTitle }) else { return false }
        var cells = Array(repeating: "", count: section.columns.count)
        cells[0] = name
        if let column = Self.heardColumn(of: section), !heard.isEmpty, !Self.same(heard, name) { cells[column] = heard }
        if let column = Self.noteColumn(of: section) { cells[column] = note }
        add(cells, to: section)
        return true
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
    private let cache = AppFiles.support.appendingPathComponent("vocabulary.md")

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
            // The request outlives the page that asked. A Mac rebuilds the page as it appears,
            // which would cancel this and leave the second ask to find the store busy.
            adopt(try await Task { try await send("GET", body: nil) }.value)
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
        .inlineTitle()
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if store.busy { ProgressView() }
                Menu {
                    Button("Reload from desktop", systemImage: "arrow.clockwise") {
                        Task { await store.load() }
                    }
                    Button("Edit as text", systemImage: "doc.plaintext") { editingText = true }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(isPresented: $editingText) { GlossaryTextView().sheetSize(width: 620, height: 520) }
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
                #if os(macOS)
                // Swiping needs a trackpad; a mouse needs a menu.
                .contextMenu {
                    Button("Delete", role: .destructive) {
                        store.glossary.remove(row)
                        Task { await store.save() }
                    }
                }
                #endif
            }
            .onDelete { offsets in
                for row in offsets.map({ current.rows[$0] }) { store.glossary.remove(row) }
                Task { await store.save() }
            }
        }
        .navigationTitle(current.title)
        .inlineTitle()
        .toolbar {
            Button("Add", systemImage: "plus") { adding = true }
        }
        .sheet(isPresented: $adding) {
            NavigationStack { GlossaryRowView(section: current, row: nil) }.sheetSize(width: 460, height: 340)
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
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                }
            }
            if section.columns.count > 1 {
                Text("Separate several mishearings with commas.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(row == nil ? "New entry" : (row?.cells.first ?? ""))
        .inlineTitle()
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
            .inlineTitle()
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
                .inlineTitle()
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

/// A name highlighted while reading a day, on its way to the glossary.
struct NameFix: Identifiable {
    let id = UUID()
    let heard: String

    /// Longer than this, a highlight is a sentence rather than a name.
    static let longest = 40

    /// What was highlighted, without the spaces, punctuation and "(?)" caught along with it.
    static func clean(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }
}

/// Fix a name from the day it was misheard in: the glossary learns the mishearing, so later
/// clips come out right, and that day's summary can be corrected where it stands.
struct NameFixView: View {
    @ObservedObject private var store = VocabularyStore.shared
    @Environment(\.dismiss) private var dismiss
    let date: String
    let summary: String?
    let onCorrected: () async -> Void
    @State private var heard: String
    @State private var name = ""
    @State private var note = ""
    @State private var sectionTitle = ""
    @State private var fixSummary = true
    @State private var saving = false
    @State private var problem: String?

    init(heard: String, date: String, summary: String?, onCorrected: @escaping () async -> Void) {
        _heard = State(initialValue: heard)
        self.date = date
        self.summary = summary
        self.onCorrected = onCorrected
    }

    private var trimmedHeard: String { heard.trimmingCharacters(in: .whitespaces) }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var tables: [Glossary.Section] { store.glossary.sections.filter(\.hasTable) }
    private var existing: Glossary.Entry? { store.glossary.entry(named: trimmedName) }
    private var confirming: Bool { trimmedHeard.caseInsensitiveCompare(trimmedName) == .orderedSame }

    /// Places in the summary this would change: every mention, or only the "(?)" when the name was right.
    private var places: Int {
        guard let summary, !trimmedHeard.isEmpty, !trimmedName.isEmpty else { return 0 }
        let name = NSRegularExpression.escapedPattern(for: trimmedHeard)
        let pattern = confirming ? name + "[ \\t]?[(（][?？][)）]" : name
        return (try? NSRegularExpression(pattern: pattern))?
            .numberOfMatches(in: summary, range: NSRange(summary.startIndex..., in: summary)) ?? 0
    }

    private var outcome: String {
        guard !trimmedName.isEmpty else { return "How summaries should spell it from now on." }
        if store.glossary.knows(heard: trimmedHeard, means: trimmedName) {
            return confirming || trimmedHeard.isEmpty ? "Already in Names and terms."
                : "Names and terms already turns “\(trimmedHeard)” into \(trimmedName)."
        }
        if let existing {
            return "Adds “\(trimmedHeard)” to \(existing.name) in \(existing.section.title)."
        }
        return "Not in Names and terms yet, so this starts an entry."
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Heard as") {
                    TextField("As it was written", text: $heard)
                        .autocorrectionDisabled()
                }
                Section {
                    TextField("Correct spelling", text: $name)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                } header: {
                    Text("Should be")
                } footer: {
                    Text(outcome)
                }
                if existing == nil && !trimmedName.isEmpty && !tables.isEmpty {
                    Section("New entry") {
                        Picker("List under", selection: $sectionTitle) {
                            ForEach(tables) { Text($0.title).tag($0.title) }
                        }
                        if let section = tables.first(where: { $0.title == sectionTitle }),
                           let column = Glossary.noteColumn(of: section) {
                            TextField(section.columns[column], text: $note)
                        }
                    }
                }
                if places > 0 {
                    Section {
                        Toggle("Also correct this day's summary", isOn: $fixSummary)
                    } footer: {
                        Text(confirming ? "Removes the (?) after it in \(places) \(places == 1 ? "place" : "places")."
                             : "Replaces “\(trimmedHeard)” in \(places) \(places == 1 ? "place" : "places").")
                    }
                }
                if let problem {
                    Section { Text(problem).foregroundStyle(.orange) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Fix a name")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Save") { Task { await save() } }
                            .disabled(trimmedName.isEmpty || store.busy)
                    }
                }
            }
            .task {
                prefill()  // From the copy saved here, so the form is ready at once.
                await store.load()
                prefill()
            }
        }
    }

    /// Start from what the glossary already says about the highlighted text.
    private func prefill() {
        if name.isEmpty, !trimmedHeard.isEmpty, let entry = store.glossary.entry(matching: trimmedHeard) {
            name = entry.name
        }
        if !tables.contains(where: { $0.title == sectionTitle }) {
            sectionTitle = tables.first?.title ?? ""
        }
    }

    private func save() async {
        saving = true
        problem = nil
        defer { saving = false }
        let heard = trimmedHeard, name = trimmedName
        // A failed earlier attempt left the edit here unsent, so send it even when nothing new was learnt.
        if store.glossary.learn(heard: heard, means: name, note: note, in: sectionTitle) || store.failed {
            await store.save()
            if store.conflict != nil {
                // The desktop changed the file since it was read; add this one entry to its copy.
                store.keepTheirs()
                store.glossary.learn(heard: heard, means: name, note: note, in: sectionTitle)
                await store.save()
            }
            if store.failed {
                problem = store.status
                return
            }
        }
        if fixSummary && places > 0 {
            do {
                _ = try await SummaryStore.shared.correct(date: date, heard: heard, name: name)
                await onCorrected()
            } catch {
                problem = "Saved in Names and terms, but the summary was not corrected: \(error.localizedDescription)"
                return
            }
        }
        dismiss()
    }
}
