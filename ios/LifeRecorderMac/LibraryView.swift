import SwiftUI

/// The Mac window: every day down the side, the chosen one beside them.
struct LibraryView: View {
    enum Item: Hashable {
        case vocabulary
        case day(String)
        case hit(SearchHit)
    }

    @Binding var generation: Int
    @ObservedObject private var store = SummaryStore.shared
    @AppStorage("textScale") private var textScale = 1.0
    @State private var selection: Item?
    @State private var query = ""
    @State private var hits: [SearchHit] = []
    @State private var searching = false

    var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 420)
        } detail: {
            detail.environment(\.textScale, CGFloat(textScale))
        }
        // The window shows what the receiver holds, so keep asking while it is open.
        .task {
            while !Task.isCancelled {
                await store.refresh()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        // Coming back to the app should not wait for the next minute.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await store.refresh() }
        }
        .onChange(of: store.days, initial: true) { _, days in
            if selection == nil, let latest = days.first { selection = .day(latest.date) }
        }
        .task(id: query) {
            guard !query.isEmpty else { hits = []; searching = false; return }
            searching = true
            // Let typing settle before reading months of transcripts.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let found = await Task.detached(priority: .userInitiated) { [query] in searchSavedDays(query) }.value
            guard !Task.isCancelled else { return }
            hits = found
            searching = false
        }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            if !query.isEmpty {
                if searching {
                    HStack { ProgressView().controlSize(.small); Text("Searching every day").foregroundStyle(.secondary) }
                } else if hits.isEmpty {
                    Text("Nothing matches “\(query)”").foregroundStyle(.secondary)
                }
                ForEach(hits) { hit in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(hit.line).lineLimit(3)
                        HStack(spacing: 5) {
                            Image(systemName: hit.inSummary ? "text.quote" : "waveform")
                            Text(DayListView.shortTitle(for: hit.date))
                            if !hit.time.isEmpty { Text("· \(hit.time)") }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .tag(Item.hit(hit))
                }
            } else {
                Label("Names and terms", systemImage: "character.book.closed").tag(Item.vocabulary)
                ForEach(months, id: \.title) { month in
                    Section(month.title) {
                        ForEach(month.days) { day in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Self.title(for: day.date))
                                Label(day.summarized ? "Summary" : "Transcript only",
                                      systemImage: day.summarized ? "text.quote" : "waveform")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                            .tag(Item.day(day.date))
                        }
                    }
                }
            }
        }
        .searchable(text: $query, placement: .sidebar, prompt: "Search every day")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 8) {
                Text(footnote).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 0)
                if store.loading {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task {
                            await store.refresh()
                            generation += 1
                        }
                    } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("Refresh")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.bar)
        }
    }

    @ViewBuilder private var detail: some View {
        switch selection {
        case .day(let date):
            DayDetailView(store: store, day: day(for: date))
                .id("\(date)|\(generation)")
                .textSelection(.enabled)
        case .hit(let hit):
            DayDetailView(store: store, day: day(for: hit.date), initialQuery: query, startInTranscript: !hit.inSummary)
                .id("\(hit.date)|\(hit.inSummary)|\(generation)")
                .textSelection(.enabled)
        case .vocabulary:
            NavigationStack { VocabularyView() }
        case nil:
            if ReceiverSettings.load() == nil {
                ContentUnavailableView {
                    Label("Not paired", systemImage: "link")
                } description: {
                    Text("Enter your receiver's address and pairing token to read your days here.")
                } actions: {
                    SettingsLink { Text("Open Settings") }
                }
            } else {
                ContentUnavailableView("No day chosen", systemImage: "book",
                                       description: Text(store.status.isEmpty ? "Choose a day from the list." : store.status))
            }
        }
    }

    private var footnote: String {
        if !store.status.isEmpty { return store.status }
        guard let synced = store.lastSynced else { return "" }
        return "Synced \(synced.formatted(date: .abbreviated, time: .shortened))"
    }

    /// Days are listed newest first; the months keep that order.
    private var months: [(title: String, days: [DaySummary])] {
        var months: [(key: String, days: [DaySummary])] = []
        for day in store.days {
            let key = String(day.date.prefix(7))
            if months.last?.key == key { months[months.count - 1].days.append(day) }
            else { months.append((key, [day])) }
        }
        return months.map { month in
            (DayListView.parse(month.days[0].date)?.formatted(.dateTime.month(.wide).year()) ?? month.key, month.days)
        }
    }

    /// Days are listed from the receiver; a hit can still be shown if that list is stale.
    private func day(for date: String) -> DaySummary {
        store.days.first { $0.date == date } ?? DaySummary(date: date, summarized: true, updated: .distantPast)
    }

    /// The month is the section's heading, so a row needs only its weekday and day.
    private static func title(for date: String) -> String {
        DayListView.parse(date)?.formatted(.dateTime.weekday(.wide).day()) ?? date
    }
}
