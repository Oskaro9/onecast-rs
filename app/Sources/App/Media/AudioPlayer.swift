import AVFoundation
import Foundation

/// Decodes Opus audio packets using Apple's `AVAudioConverter` and plays them via `AVAudioEngine`.
final class AudioPlayer {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let queue = DispatchQueue(label: "com.onecastoss.audio", qos: .userInteractive)

    private var opusFormat: AVAudioFormat?
    private var pcmFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var isStarted = false

    init() {
        var opusDesc = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 960,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        let inFmt = AVAudioFormat(streamDescription: &opusDesc)
        let outFmt = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)

        self.opusFormat = inFmt
        self.pcmFormat = outFmt

        if let inFmt, let outFmt {
            self.converter = AVAudioConverter(from: inFmt, to: outFmt)
            engine.attach(playerNode)
            engine.connect(playerNode, to: engine.mainMixerNode, format: outFmt)
        }
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.isStarted else { return }
            do {
                self.converter?.reset()
                try self.engine.start()
                self.playerNode.play()
                self.isStarted = true
            } catch {
                // Audio engine failed to start; keep streaming video silently.
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self, self.isStarted else { return }
            self.playerNode.stop()
            self.engine.stop()
            self.converter?.reset()
            self.isStarted = false
        }
    }

    func enqueueOpusPacket(_ packet: Data) {
        queue.async { [weak self] in
            guard let self,
                  self.isStarted,
                  let opusFormat = self.opusFormat,
                  let pcmFormat = self.pcmFormat,
                  let converter = self.converter
            else { return }

            let compressed = AVAudioCompressedBuffer(
                format: opusFormat,
                packetCapacity: 1,
                maximumPacketSize: packet.count
            )
            packet.withUnsafeBytes { raw in
                guard let src = raw.baseAddress else { return }
                memcpy(compressed.data, src, packet.count)
            }
            compressed.byteLength = UInt32(packet.count)
            compressed.packetCount = 1
            compressed.packetDescriptions?.pointee = AudioStreamPacketDescription(
                mStartOffset: 0,
                mVariableFramesInPacket: 0,
                mDataByteSize: UInt32(packet.count)
            )

            guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: 960) else {
                return
            }

            var provided = false
            var convError: NSError?
            let status = converter.convert(to: pcmBuffer, error: &convError) { _, outStatus in
                if provided {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                provided = true
                outStatus.pointee = .haveData
                return compressed
            }

            if status == .haveData || status == .inputRanDry, pcmBuffer.frameLength > 0 {
                self.playerNode.scheduleBuffer(pcmBuffer, completionHandler: nil)
            }
        }
    }
}
