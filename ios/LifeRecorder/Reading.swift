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
    @Published private(set) var days: [DaySummary] = []
    @Published private(set) var status = ""
    @Published private(set) var loading = false

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

    init() {
        days = (try? decoder.decode([DaySummary].self, from: Data(contentsOf: cache.appendingPathComponent("days.json")))) ?? []
    }

    func refresh() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let data = try await get("v1/days")
            struct Index: Codable { let days: [DaySummary] }
            days = try decoder.decode(Index.self, from: data).days
            try? JSONEncoder().encode(days).write(to: cache.appendingPathComponent("days.json"), options: .atomic)
            status = days.isEmpty ? "No days recorded yet" : ""
        } catch {
            status = days.isEmpty ? "Cannot reach your Mac" : "Showing what was downloaded earlier"
        }
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
    @StateObject private var store = SummaryStore()

    var body: some View {
        List {
            if !store.status.isEmpty {
                Section { Text(store.status).foregroundStyle(.secondary) }
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

    static func title(for date: String) -> String {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        guard let parsed = parser.date(from: date) else { return date }
        return parsed.formatted(date: .complete, time: .omitted)
    }
}

struct DayDetailView: View {
    let store: SummaryStore
    let day: DaySummary
    @State private var document: DayDocument?
    @State private var showTranscript = false
    @State private var loading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let document {
                    if document.summary != nil && !document.transcript.isEmpty {
                        Picker("", selection: $showTranscript) {
                            Text("Summary").tag(false)
                            Text("Transcript").tag(true)
                        }
                        .pickerStyle(.segmented)
                    }
                    MarkdownText(showTranscript || document.summary == nil
                                 ? document.transcript : document.summary!)
                } else if loading {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text("Could not load this day. Open the app while your Mac is reachable.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
        .navigationTitle(day.date)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            document = await store.document(for: day.date)
            showTranscript = document?.summary == nil
            loading = false
        }
    }
}

/// Enough Markdown for the summaries written on the Mac: headings, bullets and inline styling.
struct MarkdownText: View {
    private let lines: [String]

    init(_ text: String) {
        self.lines = text.components(separatedBy: .newlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    Color.clear.frame(height: 1)
                } else if trimmed.hasPrefix("### ") {
                    Text(String(trimmed.dropFirst(4))).font(.headline)
                } else if trimmed.hasPrefix("## ") {
                    Text(String(trimmed.dropFirst(3))).font(.title3.bold())
                } else if trimmed.hasPrefix("# ") {
                    Text(String(trimmed.dropFirst(2))).font(.title2.bold())
                } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                        Self.styled(String(trimmed.dropFirst(2)))
                    }
                } else if trimmed.hasPrefix("|") {
                    Text(trimmed).font(.caption.monospaced())
                } else {
                    Self.styled(trimmed)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private static func styled(_ text: String) -> Text {
        Text((try? AttributedString(markdown: text)) ?? AttributedString(text))
    }
}
