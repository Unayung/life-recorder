import SwiftUI

/// The glossary that fixes names and technical terms before transcription. It lives on the
/// desktop, so an edit made here is sent back and applies to the next clip.
struct VocabularyDocument: Codable {
    let text: String
    let updated: String
}

@MainActor
final class VocabularyStore: ObservableObject {
    static let shared = VocabularyStore()

    @Published var text = ""
    @Published private(set) var status = ""
    @Published private(set) var busy = false
    @Published private(set) var saved = false
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
        text = (try? String(contentsOf: cache, encoding: .utf8)) ?? ""
    }

    func load() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let document = try await send("GET", body: nil)
            adopt(document)
            status = ""
        } catch {
            // The last copy is still worth showing; an edit can wait for the desktop.
            status = text.isEmpty ? "Could not reach your desktop." : "Showing the last saved copy."
        }
    }

    /// Send the edit. `force` replaces whatever is there, for when the desktop changed too.
    func save(force: Bool = false) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        saved = false
        do {
            let document = try await send("PUT", body: ["text": text, "updated": force ? nil : updated])
            adopt(document)
            conflict = nil
            saved = true
            status = "Saved. The next clip uses it."
        } catch VocabularyError.changedOnDesktop(let theirs) {
            conflict = theirs
            status = "This changed on your desktop while you were editing."
        } catch {
            status = "Could not save. Your edit is kept here; try again when your desktop is reachable."
        }
    }

    func keepTheirs() {
        guard let conflict else { return }
        adopt(conflict)
        self.conflict = nil
        status = "Using the desktop's version."
    }

    private func adopt(_ document: VocabularyDocument) {
        text = document.text
        updated = document.updated
        try? document.text.write(to: cache, atomically: true, encoding: .utf8)
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
    @FocusState private var editing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextEditor(text: $store.text)
                .font(.system(.body, design: .monospaced))
                .focused($editing)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
            VStack(alignment: .leading, spacing: 6) {
                if !store.status.isEmpty {
                    Text(store.status)
                        .font(.footnote)
                        .foregroundStyle(store.saved ? Color.secondary : Color.orange)
                }
                Text("Names and terms here are given to the transcriber before each clip. Put the ones that matter most under the 提示詞用 heading.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary)
        }
        .navigationTitle("Names and terms")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if store.busy { ProgressView() }
                Button("Save") { editing = false; Task { await store.save() } }
                    .disabled(store.busy || store.text.isEmpty)
            }
            ToolbarItem(placement: .keyboard) {
                Button("Done") { editing = false }.frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .task { await store.load() }
        .alert("Changed on your desktop", isPresented: Binding(get: { store.conflict != nil },
                                                               set: { if !$0 { store.conflict = nil } })) {
            Button("Keep mine") { Task { await store.save(force: true) } }
            Button("Use the desktop's", role: .cancel) { store.keepTheirs() }
        } message: {
            Text("Someone edited the glossary while this was open. Keeping yours replaces theirs.")
        }
    }
}
