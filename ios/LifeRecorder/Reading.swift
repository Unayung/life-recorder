import Foundation
import SwiftUI

struct DaySummary: Codable, Identifiable, Hashable {
    let date: String
    let summarized: Bool
    let updated: Date
    var id: String { date }
}

struct DayDocument: Codable {
    let date: String
    let summary: String?
    let transcript: String
}

/// Reads days and their summaries back from the Mac, and keeps the last answer on disk
/// so the phone still shows something when the Mac is asleep or out of reach.
@MainActor
final class SummaryStore: ObservableObject {
    /// One store for the whole app, so a sync started when the app opens is the same
    /// one the reading page shows.
    static let shared = SummaryStore()

    @Published private(set) var days: [DaySummary] = []
    @Published private(set) var status = ""
    @Published private(set) var loading = false
    @Published private(set) var lastSynced: Date? = UserDefaults.standard.object(forKey: "readingLastSynced") as? Date

    private let cache: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = support.appendingPathComponent("Reading", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        return url
    }()

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.allowsCellularAccess = true
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        return URLSession(configuration: config, delegate: PinnedTransport.shared, delegateQueue: nil)
    }()

    private lazy var decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private lazy var encoder: JSONEncoder = {
        // Must match the decoder: a default encoder writes dates as numbers, which the
        // ISO-8601 decoder rejects, and the saved list came back empty offline.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private init() {
        days = (try? decoder.decode([DaySummary].self, from: Data(contentsOf: cache.appendingPathComponent("days.json")))) ?? []
    }

    /// Fetch the day list and every day that changed since it was saved, so the whole
    /// archive stays readable on the phone when the Mac is out of reach.
    func refresh() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let data = try await get("v1/days")
            struct Index: Codable { let days: [DaySummary] }
            let fresh = try decoder.decode(Index.self, from: data).days
            days = fresh
            try? encoder.encode(fresh).write(to: cache.appendingPathComponent("days.json"), options: .atomic)
            for day in fresh where isStale(day) {
                if let document = try? await get("v1/days/\(day.date)") {
                    try? document.write(to: cache.appendingPathComponent(day.date + ".json"), options: .atomic)
                }
            }
            lastSynced = Date()
            UserDefaults.standard.set(lastSynced, forKey: "readingLastSynced")
            status = fresh.isEmpty ? "No days recorded yet" : ""
        } catch {
            status = days.isEmpty ? "Cannot reach your Mac, and nothing is saved on this phone yet"
                                  : "Offline — showing the copies saved on this phone"
        }
    }

    private func isStale(_ day: DaySummary) -> Bool {
        let file = cache.appendingPathComponent(day.date + ".json")
        guard let saved = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
        else { return true }
        return saved < day.updated
    }

    func document(for date: String) async -> DayDocument? {
        let file = cache.appendingPathComponent(date + ".json")
        if let data = try? await get("v1/days/\(date)"), let document = try? decoder.decode(DayDocument.self, from: data) {
            try? data.write(to: file, options: .atomic)
            return document
        }
        // The Mac is unreachable; fall back to whatever was read last time.
        guard let cached = try? Data(contentsOf: file) else { return nil }
        return try? decoder.decode(DayDocument.self, from: cached)
    }

    private func get(_ path: String) async throws -> Data {
        guard let settings = ReceiverSettings.load() else { throw URLError(.userAuthenticationRequired) }
        var request = URLRequest(url: settings.baseURL.appendingPathComponent(path))
        request.setValue("Bearer " + settings.token, forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }
}

struct DayListView: View {
    @ObservedObject private var store = SummaryStore.shared

    var body: some View {
        List {
            Section {
                if !store.status.isEmpty {
                    Text(store.status).foregroundStyle(.secondary)
                }
                if let synced = store.lastSynced {
                    Label("Saved on this phone · synced \(synced.formatted(date: .abbreviated, time: .shortened))",
                          systemImage: "arrow.down.circle")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            ForEach(store.days) { day in
                // The destination is built here rather than routed by value: a
                // navigationDestination registered inside a pushed view can fail to match.
                NavigationLink {
                    DayDetailView(store: store, day: day)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Self.title(for: day.date)).font(.headline)
                        HStack(spacing: 6) {
                            Image(systemName: day.summarized ? "text.quote" : "waveform")
                            Text(day.summarized ? "Summary ready" : "Transcript only")
                            Text("· updated \(day.updated.formatted(date: .omitted, time: .shortened))")
                        }
                        .font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle("Days")
        .refreshable { await store.refresh() }
        .overlay { if store.loading && store.days.isEmpty { ProgressView() } }
        .task { await store.refresh() }
    }

    static func parse(_ date: String) -> Date? {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        return parser.date(from: date)
    }

    static func title(for date: String) -> String {
        parse(date)?.formatted(date: .complete, time: .omitted) ?? date
    }

    static func shortTitle(for date: String) -> String {
        parse(date)?.formatted(date: .abbreviated, time: .omitted) ?? date
    }
}

struct DayDetailView: View {
    let store: SummaryStore
    let day: DaySummary
    @State private var document: DayDocument?
    @State private var blocks: [Block] = []
    @State private var showTranscript = false
    @State private var loading = true
    @State private var query = ""
    @AppStorage("dayNewestFirst") private var newestFirst = true

    private var shown: String {
        guard let document else { return "" }
        return showTranscript || document.summary == nil ? document.transcript : (document.summary ?? "")
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Section headers pin to the top, so the hour or topic you are reading stays visible.
                LazyVStack(alignment: .leading, spacing: 14, pinnedViews: [.sectionHeaders]) {
                    if let document {
                        if document.summary != nil && !document.transcript.isEmpty {
                            Picker("", selection: $showTranscript) {
                                Text("Summary").tag(false)
                                Text("Transcript").tag(true)
                            }
                            .pickerStyle(.segmented)
                        }
                        Text("Updated \(day.updated.formatted(date: .omitted, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(sections) { section in
                            Section {
                                ForEach(section.blocks) { block in BlockView(block: block) }
                            } header: {
                                if let heading = section.heading {
                                    HStack(alignment: .firstTextBaseline) {
                                        BlockView(block: heading)
                                        Spacer(minLength: 12)
                                        // Share one part of the day without sending the whole of it.
                                        ShareLink(item: markdown(of: section)) {
                                            Image(systemName: "square.and.arrow.up").font(.footnote)
                                        }
                                        .foregroundStyle(.secondary)
                                    }
                                    .id(heading.id)
                                    .padding(.vertical, 6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.background)
                                }
                            }
                        }
                        if sections.isEmpty && !query.isEmpty {
                            ContentUnavailableView.search(text: query)
                        }
                        Color.clear.frame(height: 40)
                    } else if loading {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                    } else {
                        ContentUnavailableView("Not downloaded yet", systemImage: "wifi.slash",
                            description: Text("Open this day once while your Mac is reachable."))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Picker("Order", selection: $newestFirst) {
                            Text("Newest first").tag(true)
                            Text("Earliest first").tag(false)
                        }
                        if headings.count > 1 {
                            Section("Jump to") {
                                ForEach(headings) { heading in
                                    Button(heading.plainText) {
                                        withAnimation { proxy.scrollTo(heading.id, anchor: .top) }
                                    }
                                }
                            }
                        }
                    } label: { Image(systemName: "list.bullet.indent") }
                    if !shown.isEmpty {
                        ShareLink(item: shown) { Image(systemName: "square.and.arrow.up") }
                    }
                }
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic),
                    prompt: showTranscript ? "Search this day" : "Search the summary")
        .navigationTitle(DayListView.shortTitle(for: day.date))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            document = await store.document(for: day.date)
            showTranscript = document?.summary == nil
            blocks = Block.parse(shown)
            loading = false
        }
        .onChange(of: showTranscript) { _, _ in blocks = Block.parse(shown) }
    }

    private var headings: [Block] {
        sections.compactMap(\.heading)
    }

    /// One section's Markdown, headed by the day it belongs to.
    private func markdown(of section: DaySection) -> String {
        let whole = allSections.first { $0.id == section.id } ?? section
        let parts = [DayListView.title(for: day.date), whole.heading?.markdown]
            + whole.blocks.map(\.markdown)
        return parts.compactMap { $0 }.joined(separator: "\n\n")
    }

    /// Blocks grouped under the heading they follow, with the search filter applied to the body.
    private var sections: [DaySection] {
        let sections = ordered(allSections)
        guard !query.isEmpty else { return sections.filter { $0.heading != nil || !$0.blocks.isEmpty } }
        let needle = query.lowercased()
        return sections.compactMap { section in
            let matches = section.blocks.filter { $0.plainText.lowercased().contains(needle) }
            let headingMatches = section.heading?.plainText.lowercased().contains(needle) ?? false
            guard !matches.isEmpty || headingMatches else { return nil }
            return DaySection(id: section.id, heading: section.heading,
                              blocks: headingMatches && matches.isEmpty ? section.blocks : matches)
        }
    }

    /// Newest first, but whatever opens the day (the date, a note about gaps) stays at the top.
    private func ordered(_ sections: [DaySection]) -> [DaySection] {
        guard newestFirst else { return sections }
        let opening = sections.prefix { $0.heading == nil }
        return opening + sections.dropFirst(opening.count).reversed()
    }

    private var allSections: [DaySection] {
        var sections: [DaySection] = []
        var current = DaySection(id: -1, heading: nil, blocks: [])
        for block in blocks {
            if case .heading(_, let level) = block.kind, level <= 3 {
                if current.heading != nil || !current.blocks.isEmpty { sections.append(current) }
                current = DaySection(id: block.id, heading: block, blocks: [])
            } else {
                current.blocks.append(block)
            }
        }
        sections.append(current)
        return sections
    }
}

struct DaySection: Identifiable {
    let id: Int
    let heading: Block?
    var blocks: [Block]
}

/// One piece of a day: the summaries written on the Mac are Markdown, and the
/// transcripts are hourly headings followed by "[HH:MM] text" entries.
struct Block: Identifiable {
    enum Kind {
        case heading(String, level: Int)
        case paragraph(String)
        case bullet(String)
        case entry(time: String, text: String)
        case table([[String]])
    }

    let id: Int
    let kind: Kind

    var plainText: String {
        switch kind {
        case .heading(let text, _): return Block.shortenHeading(text)
        case .paragraph(let text), .bullet(let text): return text
        case .entry(let time, let text): return "\(time) \(text)"
        case .table(let rows): return rows.first?.joined(separator: " ") ?? ""
        }
    }

    var markdown: String {
        switch kind {
        case .heading(let text, let level): return String(repeating: "#", count: level) + " " + text
        case .paragraph(let text): return text
        case .bullet(let text): return "- " + text
        case .entry(let time, let text): return "[\(time)] \(text)"
        case .table(let rows): return rows.map { "| " + $0.joined(separator: " | ") + " |" }.joined(separator: "\n")
        }
    }

    /// Transcript hours arrive as "2026-09-15 13:00 (UTC+08:00)"; the date is already the title.
    static func shortenHeading(_ text: String) -> String {
        guard text.count > 16, text.prefix(4).allSatisfy(\.isNumber),
              let space = text.firstIndex(of: " ") else { return text }
        return String(text[text.index(after: space)...])
            .replacingOccurrences(of: " (UTC+08:00)", with: "")
    }

    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var table: [[String]] = []
        var next = 0

        func add(_ kind: Kind) {
            blocks.append(Block(id: next, kind: kind))
            next += 1
        }
        func flushTable() {
            guard !table.isEmpty else { return }
            add(.table(table))
            table = []
        }

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("|") {
                let cells = line.split(separator: "|", omittingEmptySubsequences: true)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                // Skip the |---|---| rule under a header row.
                if !cells.isEmpty && !cells.allSatisfy({ $0.allSatisfy { $0 == "-" || $0 == ":" } }) {
                    table.append(cells)
                }
                continue
            }
            flushTable()
            if line.isEmpty { continue }
            if line.hasPrefix("### ") { add(.heading(String(line.dropFirst(4)), level: 3)) }
            else if line.hasPrefix("## ") { add(.heading(String(line.dropFirst(3)), level: 2)) }
            else if line.hasPrefix("# ") { add(.heading(String(line.dropFirst(2)), level: 1)) }
            else if line.hasPrefix("- ") || line.hasPrefix("* ") { add(.bullet(String(line.dropFirst(2)))) }
            else if let entry = timestamp(line) { add(.entry(time: entry.time, text: entry.text)) }
            else { add(.paragraph(line)) }
        }
        flushTable()
        return blocks
    }

    private static func timestamp(_ line: String) -> (time: String, text: String)? {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
        let time = String(line[line.index(after: line.startIndex)..<close])
        guard time.count == 5, time.contains(":"), time.first?.isNumber == true else { return nil }
        return (time, String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces))
    }
}

struct BlockView: View {
    let block: Block

    var body: some View {
        switch block.kind {
        case .heading(let text, let level):
            VStack(alignment: .leading, spacing: 6) {
                Text(Block.shortenHeading(text))
                    .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                    .foregroundStyle(level >= 3 ? .secondary : .primary)
                if level <= 2 { Divider() }
            }
            .padding(.top, level == 1 ? 0 : 12)

        case .paragraph(let text):
            Self.styled(text).font(.body).lineSpacing(5)

        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("•").font(.body).foregroundStyle(.secondary)
                Self.styled(text).font(.body).lineSpacing(5)
            }

        case .entry(let time, let text):
            HStack(alignment: .top, spacing: 12) {
                Text(time)
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .leading)
                    .padding(.top, 3)
                Self.styled(text).font(.callout).lineSpacing(4)
            }

        case .table(let rows):
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Self.styled(cell).font(index == 0 ? .footnote.bold() : .footnote)
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private static func styled(_ text: String) -> Text {
        Text((try? AttributedString(markdown: text)) ?? AttributedString(text))
    }
}
