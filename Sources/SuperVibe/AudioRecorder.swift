import Accelerate
import AVFoundation
import Foundation

final class AudioRecorder {

    var onAudioChunk: ((Data) -> Void)?
    var onAudioLevel: ((Float) -> Void)?

    private var audioEngine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private let dataLock = NSLock()
    private var accumulatedPCM = Data()
    private(set) var isRecording = false

    // MARK: - Start

    func start() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecorderError.noInputDevice
        }

        // AVAudioConverter: hardware-accelerated resample + mono mix + Int16 conversion
        let outFmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
        guard let conv = AVAudioConverter(from: inputFormat, to: outFmt) else {
            throw RecorderError.converterFailed
        }
        self.converter = conv
        self.outputFormat = outFmt

        inputNode.installTap(
            onBus: 0,
            bufferSize: 4096,
            format: inputFormat
        ) { [weak self] buffer, _ in
            self?.processBuffer(buffer)
        }

        // Pre-allocate ~10 min of 16kHz mono Int16 to avoid reallocation during recording
        accumulatedPCM.reserveCapacity(16000 * 2 * 600)

        engine.prepare()
        try engine.start()
        audioEngine = engine
        isRecording = true
        log("[Audio] Recording started (\(inputFormat.sampleRate) Hz, \(inputFormat.channelCount) ch -> 16kHz mono)")
    }

    // MARK: - Stop

    @discardableResult
    func stop() -> Data {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        converter = nil
        outputFormat = nil
        isRecording = false

        dataLock.lock()
        let data = accumulatedPCM
        accumulatedPCM = Data()
        dataLock.unlock()

        log("[Audio] Recording stopped (\(data.count) bytes)")
        return data
    }

    // MARK: - Processing

    private func processBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let outputFormat else { return }
        guard let floatData = buffer.floatChannelData else { return }

        let frameCount = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)

        // RMS via vDSP (hardware-accelerated sum-of-squares)
        var totalSumSq: Float = 0
        for ch in 0..<channels {
            var chSumSq: Float = 0
            vDSP_svesq(floatData[ch], 1, &chSumSq, vDSP_Length(frameCount))
            totalSumSq += chSumSq
        }
        let rms = sqrt(totalSumSq / Float(frameCount * channels))
        let db = 20 * log10(max(rms, 1e-7))
        let normalized = (db + 50) / 50  // -50dB..0dB -> 0..1
        let level = max(Float(0), min(Float(1), normalized))
        onAudioLevel?(level)

        // Resample + mono mix + Int16 via AVAudioConverter
        let ratio = buffer.format.sampleRate / outputFormat.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) / ratio) + 1)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCapacity) else { return }

        var error: NSError?
        var consumed = false
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        if error != nil || outputBuffer.frameLength == 0 { return }

        // Extract Int16 PCM bytes
        guard let int16Ptr = outputBuffer.int16ChannelData else { return }
        let byteCount = Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size
        let pcmData = Data(bytes: int16Ptr[0], count: byteCount)

        dataLock.lock()
        accumulatedPCM.append(pcmData)
        dataLock.unlock()

        onAudioChunk?(pcmData)
    }

    // MARK: - WAV Export

    /// Stop recording and save accumulated PCM data as a 16kHz mono WAV file.
    func stopAndSaveWAV() throws -> URL {
        let pcmData = stop()
        guard !pcmData.isEmpty else {
            throw RecorderError.noAudioData
        }

        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("supervibe-\(UUID().uuidString.prefix(8)).wav")
        try encodeWAV(pcmData: pcmData, sampleRate: 16000, to: wavURL)
        log("[Audio] Saved WAV to \(wavURL.path) (\(pcmData.count) bytes PCM)")
        return wavURL
    }

    private func encodeWAV(pcmData: Data, sampleRate: Int, to url: URL) throws {
        let dataSize = pcmData.count
        let fileSize = 36 + dataSize

        var data = Data()
        data.reserveCapacity(44 + dataSize)
        // RIFF header
        data.append(contentsOf: "RIFF".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(fileSize).littleEndian) { Array($0) })
        data.append(contentsOf: "WAVE".utf8)
        // fmt chunk
        data.append(contentsOf: "fmt ".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })  // PCM
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })  // mono
        data.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate * 2).littleEndian) { Array($0) })  // byte rate
        data.append(contentsOf: withUnsafeBytes(of: UInt16(2).littleEndian) { Array($0) })  // block align
        data.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian) { Array($0) }) // bits per sample
        // data chunk
        data.append(contentsOf: "data".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(dataSize).littleEndian) { Array($0) })
        data.append(pcmData)

        try data.write(to: url)
    }

    // MARK: - Error

    enum RecorderError: LocalizedError {
        case noInputDevice
        case converterFailed
        case noAudioData

        var errorDescription: String? {
            switch self {
            case .noInputDevice:
                return "No audio input device available"
            case .converterFailed:
                return "Failed to create audio format converter"
            case .noAudioData:
                return "No audio data recorded"
            }
        }
    }
}
