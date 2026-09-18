// Record meetings on a Mac (microphone + everything the Mac plays) and upload them like the phone does.
//
// Recording starts when a meeting app (Edge, Chrome, Slack, Zoom, Teams) opens the microphone and stops
// 30 seconds after it lets go, so videos and music outside calls are never captured. System audio comes
// from a Core Audio process tap (macOS 15+), so no virtual audio driver is needed.
import AVFoundation
import CoreAudio
import CryptoKit
import Foundation

let defaultApps = ["com.microsoft.edgemac", "com.google.Chrome", "com.tinyspeck.slackmacgap", "us.zoom.xos",
                   "com.microsoft.teams2"]
let graceSeconds: TimeInterval = 30  // A muted mic or a rejoin shouldn't split one meeting into two recordings.
let segmentSeconds = 60.0
let outputRate = 16_000.0

func log(_ message: String) {
    print("\(ISO8601DateFormatter().string(from: Date())) \(message)")
    fflush(stdout)
}

struct CoreAudioError: Error, CustomStringConvertible {
    let what: String, status: OSStatus
    var description: String { "\(what) failed (OSStatus \(status))" }
}

func check(_ status: OSStatus, _ what: String) throws {
    if status != noErr { throw CoreAudioError(what: what, status: status) }
}

// MARK: Core Audio properties

let systemObject = AudioObjectID(kAudioObjectSystemObject)

func address(_ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func read<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T,
             scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
    var addr = address(selector, scope), value = initial, size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr ? value : nil
}

func readObjects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
    var addr = address(selector, scope), size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var addr = address(selector), value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
    return value?.takeRetainedValue() as String?
}

func processObject(for pid: pid_t) -> AudioObjectID? {
    var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject), pid = pid
    var object = AudioObjectID(kAudioObjectUnknown), size = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = AudioObjectGetPropertyData(systemObject, &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
    return status == noErr && object != kAudioObjectUnknown ? object : nil
}

func defaultInputDevice() -> AudioObjectID? {
    read(systemObject, kAudioHardwarePropertyDefaultInputDevice, AudioObjectID(kAudioObjectUnknown))
        .flatMap { $0 == kAudioObjectUnknown ? nil : $0 }
}

/// Processes other than this one that are currently taking microphone input.
func micClients() -> [(pid: pid_t, bundle: String)] {
    readObjects(systemObject, kAudioHardwarePropertyProcessObjectList).compactMap { object in
        guard read(object, kAudioProcessPropertyIsRunningInput, UInt32(0)) == 1,
              let pid = read(object, kAudioProcessPropertyPID, pid_t(0)), pid != getpid() else { return nil }
        return (pid, readString(object, kAudioProcessPropertyBundleID) ?? "")
    }
}

/// Bundle IDs match by prefix, so a browser's helper processes (which own the mic in Chromium) count too.
func meetingApp(_ apps: [String]) -> String? {
    micClients().first { client in apps.contains { client.bundle.hasPrefix($0) } }?.bundle
}

// MARK: Recording

/// Writes mono 16 kHz AAC in 60-second files named by their UTC start time. A file is moved into the spool
/// only once it is closed, so the uploader never sees one that is still being written.
final class SegmentWriter {
    private let spool: URL, partial: URL
    private let input: AVAudioFormat, output: AVAudioFormat, converter: AVAudioConverter
    private var file: AVAudioFile?, name = "", frames: AVAudioFramePosition = 0, lastError = ""

    init(spool: URL, inputRate: Double) throws {
        self.spool = spool
        partial = spool.appendingPathComponent("recording")
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 1, interleaved: false)!
        output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: outputRate, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: input, to: output) else {
            throw CoreAudioError(what: "Sample rate converter", status: -1)
        }
        self.converter = converter
    }

    func append(_ samples: [Float]) {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(samples.count)),
              let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity:
                AVAudioFrameCount(Double(samples.count) * outputRate / input.sampleRate) + 64) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
        var fed = false, error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard converted.frameLength > 0 else { return }
        do {
            if file == nil { try open() }
            try file!.write(from: converted)
            frames += AVAudioFramePosition(converted.frameLength)
            if Double(frames) >= segmentSeconds * outputRate { close() }
        } catch {
            // Log a repeating failure once, and drop the broken file rather than uploading it.
            if "\(error)" != lastError { log("writing \(name) failed: \(error)") }
            lastError = "\(error)"
            file = nil
            try? FileManager.default.removeItem(at: partial.appendingPathComponent(name))
        }
    }

    private func open() throws {
        name = segmentName(Date())
        frames = 0
        file = try AVAudioFile(forWriting: partial.appendingPathComponent(name), settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: outputRate, AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,  // Plenty for speech; 64k is above what AAC allows at 16 kHz mono.
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    func close() {
        guard let file else { return }
        file.close()
        self.file = nil
        try? FileManager.default.moveItem(at: partial.appendingPathComponent(name),
                                          to: spool.appendingPathComponent(name))
    }
}

let nameFormat: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss-SSS"  // Milliseconds keep ids unique across quick restarts.
    return formatter
}()

func segmentName(_ date: Date) -> String { nameFormat.string(from: date) + ".m4a" }

/// A private aggregate device of the current microphone plus a tap on every other process's output,
/// mixed down to one channel.
final class MeetingCapture {
    let mic: AudioObjectID
    private var tap = AudioObjectID(kAudioObjectUnknown), aggregate = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "capture.io")
    private var writer: SegmentWriter?

    init(spool: URL) throws {
        guard let mic = defaultInputDevice(), let micUID = readString(mic, kAudioDevicePropertyDeviceUID) else {
            throw CoreAudioError(what: "Finding the microphone", status: -1)
        }
        self.mic = mic
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: processObject(for: getpid()).map { [$0] } ?? [])
        description.uuid = UUID()
        description.name = "Life Recorder meeting"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(description, &tap), "Creating the system audio tap")
        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Life Recorder meeting",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: micUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: micUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString,
                                               kAudioSubTapDriftCompensationKey: true]],
        ]
        do {
            try check(AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregate), "Creating the aggregate device")
            // Each input stream arrives as one interleaved buffer or one buffer per channel.
            var layout: [Int] = []
            for stream in readObjects(aggregate, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput) {
                guard let format = read(stream, kAudioStreamPropertyVirtualFormat, AudioStreamBasicDescription()),
                      format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                      format.mBitsPerChannel == 32 else {
                    throw CoreAudioError(what: "Reading a 32-bit float input stream", status: -1)
                }
                layout.append(format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? Int(format.mChannelsPerFrame) : 1)
            }
            let rate = read(aggregate, kAudioDevicePropertyNominalSampleRate, Float64(0)) ?? 0
            guard rate > 0 else { throw CoreAudioError(what: "Reading the sample rate", status: -1) }
            let writer = try SegmentWriter(spool: spool, inputRate: rate)
            self.writer = writer
            try check(AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, queue) { _, input, _, _, _ in
                writer.append(MeetingCapture.mix(input, layout: layout))
            }, "Creating the capture callback")
            try check(AudioDeviceStart(aggregate, proc), "Starting capture")
        } catch {
            teardown()
            throw error
        }
    }

    /// Averages each stream's channels, then sums the streams: the microphone plus the system audio.
    static func mix(_ list: UnsafePointer<AudioBufferList>, layout: [Int]) -> [Float] {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard let first = buffers.first, first.mNumberChannels > 0 else { return [] }
        let frames = Int(first.mDataByteSize) / (4 * Int(first.mNumberChannels))
        let groups = layout.reduce(0, +) == buffers.count ? layout : Array(repeating: 1, count: buffers.count)
        var mixed = [Float](repeating: 0, count: frames), index = 0
        for count in groups {
            let group = buffers[index..<index + count]
            index += count
            let channels = group.reduce(0) { $0 + Int($1.mNumberChannels) }
            guard channels > 0 else { continue }
            let scale = 1 / Float(channels)
            for buffer in group {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let width = Int(buffer.mNumberChannels)
                for frame in 0..<min(frames, Int(buffer.mDataByteSize) / (4 * width)) {
                    for channel in 0..<width { mixed[frame] += data[frame * width + channel] * scale }
                }
            }
        }
        for i in mixed.indices { mixed[i] = max(-1, min(1, mixed[i])) }
        return mixed
    }

    func stop() {
        teardown()
        queue.sync { writer?.close() }
    }

    private func teardown() {
        if let proc {
            AudioDeviceStop(aggregate, proc)
            AudioDeviceDestroyIOProcID(aggregate, proc)
            self.proc = nil
        }
        if aggregate != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregate) }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        aggregate = AudioObjectID(kAudioObjectUnknown)
        tap = AudioObjectID(kAudioObjectUnknown)
    }
}

// MARK: Upload

/// Name-based UUID (RFC 4122 version 5), matching Python's uuid.uuid5.
func uuid5(_ namespace: UUID, _ name: String) -> UUID {
    var bytes = withUnsafeBytes(of: namespace.uuid) { Array($0) }
    bytes += Array(name.utf8)
    var hash = Array(Insecure.SHA1.hash(data: bytes).prefix(16))
    hash[6] = (hash[6] & 0x0F) | 0x50
    hash[8] = (hash[8] & 0x3F) | 0x80
    return hash.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
}

func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
    digest.map { String(format: "%02x", $0) }.joined()
}

final class Uploader: NSObject, URLSessionDelegate {
    enum Outcome { case stored, rejected, retry }

    private let dataDir: URL, spool: URL, receiver: URL, device: UUID
    private lazy var session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)

    init(dataDir: URL, spool: URL, receiver: URL, device: UUID) {
        self.dataDir = dataDir
        self.spool = spool
        self.receiver = receiver
        self.device = device
    }

    /// SHA-256 of receiver.crt's DER bytes: the same pin the phone uses (the cert names no host).
    private func pin() -> String? {
        guard let pem = try? String(contentsOf: dataDir.appendingPathComponent("receiver.crt"), encoding: .utf8) else { return nil }
        let body = pem.components(separatedBy: "\n").filter { !$0.hasPrefix("-----") }.joined()
        return Data(base64Encoded: body).map { hex(SHA256.hash(data: $0)) }
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
              let pin = pin(), hex(SHA256.hash(data: SecCertificateCopyData(leaf) as Data)) == pin else {
            return (.cancelAuthenticationChallenge, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }

    func uploadPending() async {
        let files = (try? FileManager.default.contentsOfDirectory(at: spool, includingPropertiesForKeys: nil)) ?? []
        for file in files.filter({ $0.pathExtension == "m4a" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            switch await upload(file) {
            case .stored: try? FileManager.default.removeItem(at: file)
            case .rejected: try? FileManager.default.moveItem(at: file, to: file.deletingPathExtension().appendingPathExtension("rejected"))
            case .retry: return  // Offline or asleep is normal; try again on the next pass.
            }
        }
    }

    private func upload(_ file: URL) async -> Outcome {
        let name = file.lastPathComponent
        guard let started = nameFormat.date(from: file.deletingPathExtension().lastPathComponent),
              let audio = try? AVAudioFile(forReading: file), audio.length > 0,
              let body = try? Data(contentsOf: file) else {
            log("upload \(name): unreadable, set aside")
            return .rejected
        }
        guard let token = try? String(contentsOf: dataDir.appendingPathComponent("receiver.token"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
            log("upload \(name): no receiver.token")
            return .retry
        }
        let id = uuid5(device, name).uuidString.lowercased()  // Same file, same id: retries stay idempotent.
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var request = URLRequest(url: receiver.appendingPathComponent("v1/chunks/\(id)"), timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue(device.uuidString.lowercased(), forHTTPHeaderField: "X-Device-ID")
        request.setValue(stamp.string(from: started), forHTTPHeaderField: "X-Started-At")
        request.setValue(String(format: "%.3f", Double(audio.length) / audio.fileFormat.sampleRate),
                         forHTTPHeaderField: "X-Duration-Seconds")
        request.setValue(hex(SHA256.hash(data: body)), forHTTPHeaderField: "X-Audio-SHA256")
        request.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        do {
            let (data, response) = try await session.upload(for: request, from: body)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let receipt = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if (status == 200 || status == 201) && receipt?["durable"] as? Bool == true {
                log("uploaded \(name)")
                return .stored
            }
            log("upload \(name): HTTP \(status)")
            return status == 400 ? .rejected : .retry
        } catch {
            log("upload \(name) failed: \(error.localizedDescription)")
            return .retry
        }
    }
}

// MARK: Main

func option(_ name: String) -> String? {
    let args = CommandLine.arguments
    return args.firstIndex(of: name).flatMap { args.index(after: $0) < args.endIndex ? args[$0 + 1] : nil }
}

let dataDir = URL(fileURLWithPath: option("--data-dir")
    ?? NSHomeDirectory() + "/Library/Application Support/LifeRecorder")
let receiver = URL(string: option("--receiver") ?? "https://omarchy.tail3fdc0b.ts.net:8443")!
let apps = option("--apps")?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? defaultApps

if CommandLine.arguments.contains("--list-mic-apps") {
    for client in micClients() { print("\(client.pid)\t\(client.bundle)") }
    exit(0)
}

if let seconds = option("--test-record").flatMap(Double.init) {
    // Record regardless of meetings into --out, without uploading; for checking levels and permissions.
    let out = URL(fileURLWithPath: option("--out") ?? FileManager.default.currentDirectoryPath)
    do {
        let capture = try MeetingCapture(spool: out)
        log("test recording \(Int(seconds))s into \(out.path)")
        Thread.sleep(forTimeInterval: seconds)
        capture.stop()
        log("test recording done")
        exit(0)
    } catch {
        log("test recording failed: \(error)")
        exit(1)
    }
}

let spool = dataDir.appendingPathComponent("desktop-spool")
try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
// Files left mid-write by a crash have no index and can never be decoded; keep them out of the upload queue.
for leftover in (try? FileManager.default.contentsOfDirectory(at: spool.appendingPathComponent("recording"),
                                                              includingPropertiesForKeys: nil)) ?? [] {
    try? FileManager.default.moveItem(at: leftover, to: spool.appendingPathComponent(
        leftover.deletingPathExtension().lastPathComponent + ".incomplete"))
}
let deviceFile = dataDir.appendingPathComponent("desktop-device-id")
if !FileManager.default.fileExists(atPath: deviceFile.path) {
    FileManager.default.createFile(atPath: deviceFile.path, contents: Data(UUID().uuidString.lowercased().utf8),
                                   attributes: [.posixPermissions: 0o600])
}
guard let device = UUID(uuidString: (try String(contentsOf: deviceFile, encoding: .utf8))
    .trimmingCharacters(in: .whitespacesAndNewlines)) else {
    log("\(deviceFile.path) does not hold a UUID")
    exit(1)
}

switch AVCaptureDevice.authorizationStatus(for: .audio) {
case .authorized: break
case .notDetermined:
    // Ask now, at install time, rather than in the first seconds of a meeting.
    AVCaptureDevice.requestAccess(for: .audio) { granted in log("microphone access \(granted ? "granted" : "denied")") }
default: log("microphone access denied; allow it in System Settings > Privacy & Security > Microphone")
}

let uploader = Uploader(dataDir: dataDir, spool: spool, receiver: receiver, device: device)
Task.detached {
    while true {
        await uploader.uploadPending()
        try? await Task.sleep(for: .seconds(15))
    }
}

let control = DispatchQueue(label: "capture.control")
var capture: MeetingCapture?
var lastSeen = Date.distantPast

func startCapture(_ reason: String) {
    do {
        capture = try MeetingCapture(spool: spool)
        log(reason)
    } catch {
        log("could not start recording: \(error)")
    }
}

func stopCapture(_ reason: String) {
    capture?.stop()
    capture = nil
    log(reason)
}

let poll = DispatchSource.makeTimerSource(queue: control)
poll.schedule(deadline: .now(), repeating: 5)
poll.setEventHandler {
    if let app = meetingApp(apps) {
        lastSeen = Date()
        if capture == nil {
            startCapture("meeting started (\(app)), recording")
        } else if let current = capture, defaultInputDevice() != current.mic {
            stopCapture("microphone changed")
            startCapture("recording with the new microphone")
        }
    } else if capture != nil && Date().timeIntervalSince(lastSeen) > graceSeconds {
        stopCapture("meeting ended, stopped")
    }
}
poll.resume()

signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
var stopSignals: [DispatchSourceSignal] = []
for number in [SIGTERM, SIGINT] {
    let source = DispatchSource.makeSignalSource(signal: number, queue: control)
    source.setEventHandler {
        if capture != nil { stopCapture("stopping, last segment saved") }
        exit(0)
    }
    source.resume()
    stopSignals.append(source)
}

log("watching for meetings (device \(device.uuidString.lowercased()), receiver \(receiver.host ?? "?"))")
dispatchMain()
