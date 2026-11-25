import AVFoundation
import CoreMedia
import Foundation
import MetalKit
import SwiftUI

enum VideoAspectMode: String, CaseIterable, Identifiable {
    case fit
    case fill
    case zoom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fit: return "Fit (16:9)"
        case .fill: return "Fill (16:10)"
        case .zoom: return "Zoom"
        }
    }

    var videoGravity: AVLayerVideoGravity {
        switch self {
        case .fit: return .resizeAspect
        case .fill: return .resize
        case .zoom: return .resizeAspectFill
        }
    }
}

/// Parses Annex-B H.264 NAL units from WebRTC and constructs hardware-decodable `CMSampleBuffer`s.
public final class H264SampleBufferBuilder {
    private var sps: Data?
    private var pps: Data?
    private var formatDescription: CMVideoFormatDescription?

    public init() {}

    /// Splits an Annex-B byte stream into individual NAL units (without start codes).
    public static func splitAnnexBNalUnits(_ data: Data) -> [Data] {
        var units: [Data] = []
        let bytes = [UInt8](data)
        var i = 0
        var nalStart: Int?

        while i < bytes.count {
            let is4Byte = i + 3 < bytes.count && bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 0 && bytes[i + 3] == 1
            let is3Byte = !is4Byte && i + 2 < bytes.count && bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 1

            if is4Byte || is3Byte {
                if let start = nalStart, start < i {
                    units.append(Data(bytes[start..<i]))
                }
                i += is4Byte ? 4 : 3
                nalStart = i
            } else {
                i += 1
            }
        }

        if let start = nalStart, start < bytes.count {
            units.append(Data(bytes[start..<bytes.count]))
        }
        return units
    }

    /// Converts an Annex-B H.264 access unit into a `CMSampleBuffer` ready for `AVSampleBufferDisplayLayer`.
    public func makeSampleBuffer(fromAnnexB data: Data, ptsUs: UInt64) -> CMSampleBuffer? {
        let nals = Self.splitAnnexBNalUnits(data)
        guard !nals.isEmpty else { return nil }

        var videoNals: [Data] = []
        var spsPpsUpdated = false

        for nal in nals {
            guard let firstByte = nal.first else { continue }
            let nalType = firstByte & 0x1F
            switch nalType {
            case 7: // SPS
                if sps != nal {
                    sps = nal
                    spsPpsUpdated = true
                }
            case 8: // PPS
                if pps != nal {
                    pps = nal
                    spsPpsUpdated = true
                }
            case 1, 5: // Non-IDR or IDR slice
                videoNals.append(nal)
            default:
                break
            }
        }

        if spsPpsUpdated || formatDescription == nil {
            guard let sps, let pps else { return nil }
            formatDescription = createFormatDescription(sps: sps, pps: pps)
        }

        guard let formatDescription, !videoNals.isEmpty else { return nil }

        // Pack slice NALs in AVCC format (4-byte big-endian length prefix).
        var avccData = Data()
        for nal in videoNals {
            var lengthBE = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &lengthBE) { avccData.append(contentsOf: $0) }
            avccData.append(nal)
        }

        var blockBuffer: CMBlockBuffer?
        let status = avccData.withUnsafeBytes { rawBuf -> OSStatus in
            guard let baseAddress = rawBuf.baseAddress else { return -1 }
            return CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: avccData.count,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: avccData.count,
                flags: 0,
                blockBufferOut: &blockBuffer
            ).flatMapStatus {
                guard let blockBuffer else { return -1 }
                return CMBlockBufferReplaceDataBytes(
                    with: baseAddress,
                    blockBuffer: blockBuffer,
                    offsetIntoDestination: 0,
                    dataLength: avccData.count
                )
            }
        }

        guard status == noErr, let blockBuffer else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime.invalid,
            presentationTimeStamp: CMTime(value: CMTimeValue(ptsUs), timescale: 1_000_000),
            decodeTimeStamp: CMTime.invalid
        )
        var sampleSize = avccData.count
        var sampleBuffer: CMSampleBuffer?

        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )

        guard sampleStatus == noErr, let sampleBuffer else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }

        return sampleBuffer
    }

    private func createFormatDescription(sps: Data, pps: Data) -> CMVideoFormatDescription? {
        var formatDesc: CMVideoFormatDescription?
        let status: OSStatus = sps.withUnsafeBytes { spsBuf in
            pps.withUnsafeBytes { ppsBuf in
                guard let spsPtr = spsBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let ppsPtr = ppsBuf.baseAddress?.assumingMemoryBound(to: UInt8.self)
                else {
                    return -1
                }
                var pointers: [UnsafePointer<UInt8>] = [spsPtr, ppsPtr]
                var sizes: [Int] = [sps.count, pps.count]
                return pointers.withUnsafeMutableBufferPointer { ptrBuf in
                    sizes.withUnsafeMutableBufferPointer { sizeBuf in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: ptrBuf.baseAddress!,
                            parameterSetSizes: sizeBuf.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &formatDesc
                        )
                    }
                }
            }
        }
        return status == noErr ? formatDesc : nil
    }
}

private extension OSStatus {
    func flatMapStatus(_ next: () -> OSStatus) -> OSStatus {
        self == noErr ? next() : self
    }
}

/// Container NSView hosting either `AVSampleBufferDisplayLayer` (native) or `MTKView` (`MetalFX`).
final class VideoContainerNSView: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()
    let mtkView = MTKView(frame: .zero)
    var metalRenderer: MetalFXVideoRenderer?
    private var currentUpscaleMode: VideoUpscaleMode = .off

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor

        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(displayLayer)

        mtkView.isHidden = true
        mtkView.autoresizingMask = [.width, .height]
        addSubview(mtkView)
        metalRenderer = MetalFXVideoRenderer(mtkView: mtkView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        displayLayer.frame = bounds
        mtkView.frame = bounds
    }

    func configure(aspectMode: VideoAspectMode, upscaleMode: VideoUpscaleMode) {
        let modeChanged = (currentUpscaleMode != upscaleMode)
        currentUpscaleMode = upscaleMode
        displayLayer.videoGravity = aspectMode.videoGravity
        metalRenderer?.setAspectMode(aspectMode)

        let useMetal = (upscaleMode == .metalFX && metalRenderer != nil)
        if modeChanged && !useMetal {
            displayLayer.flush()
        }
        displayLayer.isHidden = useMetal
        mtkView.isHidden = !useMetal
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        if currentUpscaleMode == .metalFX, let metalRenderer {
            metalRenderer.enqueueSampleBuffer(sampleBuffer, on: mtkView)
        } else {
            if displayLayer.status == .failed {
                displayLayer.flush()
            }
            displayLayer.sampleBufferRenderer.enqueue(sampleBuffer)
        }
    }

    func flush() {
        displayLayer.flushAndRemoveImage()
        metalRenderer?.reset()
    }
}

struct VideoDecoderView: NSViewRepresentable {
    let coordinatorRef: VideoRenderCoordinator
    let aspectMode: VideoAspectMode
    let upscaleMode: VideoUpscaleMode

    func makeNSView(context: Context) -> VideoContainerNSView {
        let view = VideoContainerNSView(frame: .zero)
        view.configure(aspectMode: aspectMode, upscaleMode: upscaleMode)
        coordinatorRef.attach(view: view)
        return view
    }

    func updateNSView(_ nsView: VideoContainerNSView, context: Context) {
        nsView.configure(aspectMode: aspectMode, upscaleMode: upscaleMode)
    }
}

/// Bridges background WebRTC video frames onto `AVSampleBufferDisplayLayer` or `MetalFX`.
final class VideoRenderCoordinator {
    private let builder = H264SampleBufferBuilder()
    private let queue = DispatchQueue(label: "com.onecastoss.video", qos: .userInteractive)
    private weak var displayView: VideoContainerNSView?

    func attach(view: VideoContainerNSView) {
        displayView = view
    }

    func enqueueAnnexBFrame(_ data: Data, ptsUs: UInt64) {
        queue.async { [weak self] in
            guard let self,
                  let sample = self.builder.makeSampleBuffer(fromAnnexB: data, ptsUs: ptsUs)
            else { return }
            DispatchQueue.main.async { [weak self] in
                self?.displayView?.enqueue(sample)
            }
        }
    }

    func reset() {
        DispatchQueue.main.async { [weak self] in
            self?.displayView?.flush()
        }
    }
}
