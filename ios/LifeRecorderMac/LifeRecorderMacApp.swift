import SwiftUI

@main
struct LifeRecorderMacApp: App {
    /// Raised by Refresh, so the day on screen is read again and not only the list beside it.
    @State private var generation = 0
    @AppStorage("textScale") private var textScale = 1.0

    var body: some Scene {
        Window("Life Recorder", id: "library") {
            LibraryView(generation: $generation)
                .frame(minWidth: 720, minHeight: 440)
        }
        .defaultSize(width: 1100, height: 760)
        .commands {
            SidebarCommands()
            CommandGroup(before: .sidebar) {
                Button("Make Text Bigger") { textScale = TextScale.bigger(than: textScale) }
                    .keyboardShortcut("+").disabled(TextScale.bigger(than: textScale) == textScale)
                Button("Make Text Smaller") { textScale = TextScale.smaller(than: textScale) }
                    .keyboardShortcut("-").disabled(TextScale.smaller(than: textScale) == textScale)
                Button("Actual Size") { textScale = 1 }
                    .keyboardShortcut("0").disabled(textScale == 1)
                Divider()
                Button("Refresh") {
                    Task {
                        await SummaryStore.shared.refresh()
                        generation += 1
                    }
                }
                .keyboardShortcut("r")
                Divider()
            }
        }
        Settings { PairingSettings() }
    }
}

/// The sizes a day's text steps through.
enum TextScale {
    static let steps = [0.85, 1, 1.15, 1.3, 1.5, 1.75, 2, 2.5]

    static func bigger(than scale: Double) -> Double {
        steps.first { $0 > scale + 0.001 } ?? scale
    }

    static func smaller(than scale: Double) -> Double {
        steps.last { $0 < scale - 0.001 } ?? scale
    }
}

/// Which receiver this Mac reads from.
struct PairingSettings: View {
    @State private var address = UserDefaults.standard.string(forKey: "receiverURL") ?? ""
    @State private var token = Credentials.token()
    @State private var pin = UserDefaults.standard.string(forKey: "certificateSHA256") ?? ""
    @State private var source = PairingSettings.describe()
    @State private var entered = ReceiverSettings.paired() != nil
    @State private var error: String?

    private static func describe() -> String {
        if let host = ReceiverSettings.paired()?.baseURL.host { return "\(host), entered here" }
        if let host = RecorderPairing.load()?.baseURL.host { return "\(host), through this Mac's meeting recorder" }
        return "Not paired"
    }

    private func changed() {
        source = Self.describe()
        entered = ReceiverSettings.paired() != nil
        error = nil
        Task { await SummaryStore.shared.refresh() }
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Reading from", value: source)
            }
            Section {
                TextField("Address", text: $address, prompt: Text("https://receiver:8765"))
                    .autocorrectionDisabled()
                SecureField("Pairing token", text: $token)
                TextField("Certificate fingerprint", text: $pin, axis: .vertical)
                    .font(.caption.monospaced()).autocorrectionDisabled()
            } header: {
                Text("Another receiver")
            } footer: {
                Text("A Mac that runs the meeting recorder is paired through it and needs nothing here. Otherwise use the address, token and fingerprint from the pairing page receiver/setup.py wrote.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                if entered {
                    Button("Use the Meeting Recorder's Pairing") {
                        ReceiverSettings.forget()
                        address = ""
                        pin = ""
                        changed()
                    }
                }
                Spacer()
                Button("Save") {
                    do {
                        try ReceiverSettings.save(url: address, token: token, pin: pin)
                        changed()
                    } catch { self.error = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}
