import AVFoundation
import Foundation

/// The capture tap copies buffers here; this serial queue preserves their order across file rotations.
final class ChunkWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "life.recorder.audio-writer", qos: .utility)
    private var file: AVAudioFile?
    private var journal: RecordingJournal?
    private var chunkFrames: Int64 = 0
    private var totalFrames: Int64 = 0
    private let startedAt = Date()
    private var sampleRate: Double = 48000
    private var failed = false
    /// The loudest short window in the clip being written, as amplitude (1.0 is full scale).
    private var loudest: Float = 0
    private var windowSum: Float = 0
    private var windowFrames = 0
    private let onChunk: () -> Void
    private let onError: (String) -> Void

    init(onChunk: @escaping () -> Void, onError: @escaping (String) -> Void) {
        self.onChunk = onChunk
        self.onError = onError
    }

    func consume(_ input: AVAudioPCMBuffer) {
        // AVAudioEngine reuses the tap's memory after the callback returns.
        guard let copy = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: input.frameLength) else { return }
        copy.frameLength = input.frameLength
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input.audioBufferList))
        let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in 0..<src.count {
            guard let source = src[index].mData, let destination = dst[index].mData else { return }
            memcpy(destination, source, Int(src[index].mDataByteSize))
        }
        queue.async { [self] in
            guard !failed else { return }
            do {
                if file == nil { try begin(format: copy.format) }
                measure(copy)
                try file?.write(from: copy)
                chunkFrames += Int64(copy.frameLength)
                totalFrames += Int64(copy.frameLength)
                if Double(chunkFrames) / sampleRate >= 60 { try finishChunk() }
            } catch {
                failed = true
                onError(error.localizedDescription)
            }
        }
    }

    /// Loudness in 100 ms windows: a minute is silence only if none of its windows rose above the
    /// threshold. Windows, not a whole-clip average, so one sentence in a quiet hour still counts.
    private func measure(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { loudest = 1; return }  // Unknown format: keep it.
        let window = Int(sampleRate / 10)
        let stride = buffer.stride
        for frame in 0..<Int(buffer.frameLength) {
            var sum: Float = 0
            for channel in 0..<Int(buffer.format.channelCount) {
                let sample = channels[channel][frame * stride]
                sum += sample * sample
            }
            windowSum += sum / Float(buffer.format.channelCount)
            windowFrames += 1
            if windowFrames >= window {
                loudest = max(loudest, (windowSum / Float(windowFrames)).squareRoot())
                windowSum = 0
                windowFrames = 0
            }
        }
    }

    private func begin(format: AVAudioFormat) throws {
        let capacity = try QueueStore.directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let free = capacity.volumeAvailableCapacityForImportantUsage, free < 200 * 1024 * 1024 {
            throw NSError(domain: "Recorder", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Storage is nearly full. Pending audio is preserved; free space to resume."])
        }
        sampleRate = format.sampleRate
        let next = RecordingJournal(id: UUID(), startedAt: startedAt.addingTimeInterval(Double(totalFrames) / sampleRate))
        let name = next.id.uuidString.lowercased()
        let journalURL = QueueStore.directory.appendingPathComponent(name + ".recording.json")
        try JSONEncoder().encode(next).write(to: journalURL, options: .atomic)
        let outputURL = QueueStore.directory.appendingPathComponent(name + ".m4a")
        file = try AVAudioFile(forWriting: outputURL, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVEncoderBitRateKey: 32000 * Int(format.channelCount)
        ], commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                              ofItemAtPath: outputURL.path)
        journal = next
        chunkFrames = 0
    }

    private func finishChunk() throws {
        file = nil // Closing finalizes the M4A container before computing the checksum.
        guard let journal, chunkFrames > 0 else { return }
        let peak = loudest
        loudest = 0
        windowSum = 0
        windowFrames = 0
        if SilenceGate.shouldSkip(peak: peak) {
            QueueStore.discardRecording(journal)
            SilenceGate.recordSkipped(peak: peak)
            self.journal = nil
            chunkFrames = 0
            return
        }
        SilenceGate.recordKept()
        _ = try QueueStore.seal(journal, duration: Double(chunkFrames) / sampleRate)
        self.journal = nil
        chunkFrames = 0
        onChunk()
    }

    func finish() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                do { try finishChunk() } catch { onError(error.localizedDescription) }
                continuation.resume()
            }
        }
    }
}
