import CoreMedia
import CoreVideo
import Foundation
import Metal
import MetalFX
import MetalKit
import SwiftUI
import VideoToolbox

enum VideoUpscaleMode: String, CaseIterable, Identifiable {
    case off
    case metalFX

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Off"
        case .metalFX: return "MetalFX"
        }
    }
}

/// Hardware-decodes H.264 via `VTDecompressionSession` and upscales frames with `MTLFXSpatialScaler`.
final class MetalFXVideoRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var textureCache: CVMetalTextureCache?

    private var decompressionSession: VTDecompressionSession?
    private var currentFormatDesc: CMVideoFormatDescription?

    private var scaler: MTLFXSpatialScaler?
    private var scalerKey: String = ""
    private var upscaledTexture: MTLTexture?

    private let frameLock = NSLock()
    private var latestPixelBuffer: CVPixelBuffer?
    private var aspectMode: VideoAspectMode = .fit

    init?(mtkView: MTKView) {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let queue = dev.makeCommandQueue()
        else { return nil }

        self.device = dev
        self.commandQueue = queue
        super.init()

        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, dev, nil, &textureCache)

        mtkView.device = dev
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.framebufferOnly = false
        mtkView.isPaused = true
        mtkView.enableSetNeedsDisplay = false
        mtkView.delegate = self
    }

    deinit {
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
        }
    }

    func setAspectMode(_ mode: VideoAspectMode) {
        frameLock.lock()
        aspectMode = mode
        frameLock.unlock()
    }

    func reset() {
        frameLock.lock()
        latestPixelBuffer = nil
        frameLock.unlock()
        if let cache = textureCache {
            CVMetalTextureCacheFlush(cache, 0)
        }
    }

    func enqueueSampleBuffer(_ sampleBuffer: CMSampleBuffer, on mtkView: MTKView) {
        guard let fmt = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }

        if currentFormatDesc == nil || !CMFormatDescriptionEqual(fmt, otherFormatDescription: currentFormatDesc!) {
            rebuildDecompressionSession(formatDescription: fmt)
        }

        guard let session = decompressionSession else { return }

        var flagsOut = VTDecodeInfoFlags()
        VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [._EnableAsynchronousDecompression],
            infoFlagsOut: &flagsOut
        ) { [weak self, weak mtkView] status, _, imageBuffer, _, _ in
            guard status == noErr, let imageBuffer else { return }
            self?.frameLock.lock()
            self?.latestPixelBuffer = imageBuffer
            self?.frameLock.unlock()
            DispatchQueue.main.async {
                mtkView?.draw()
            }
        }
    }

    private func rebuildDecompressionSession(formatDescription: CMVideoFormatDescription) {
        if let existing = decompressionSession {
            VTDecompressionSessionInvalidate(existing)
            decompressionSession = nil
        }

        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        var sessionOut: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: attrs as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &sessionOut
        )
        if status == noErr {
            decompressionSession = sessionOut
            currentFormatDesc = formatDescription
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        frameLock.lock()
        let pixelBuffer = latestPixelBuffer
        let mode = aspectMode
        frameLock.unlock()

        guard let pixelBuffer,
              let cache = textureCache,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer()
        else { return }

        let srcW = CVPixelBufferGetWidth(pixelBuffer)
        let srcH = CVPixelBufferGetHeight(pixelBuffer)
        let dstW = Int(view.drawableSize.width)
        let dstH = Int(view.drawableSize.height)
        guard srcW > 0, srcH > 0, dstW > 0, dstH > 0 else { return }

        var cvTex: CVMetalTexture?
        let cvStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            srcW,
            srcH,
            0,
            &cvTex
        )
        guard cvStatus == kCVReturnSuccess,
              let cvTex,
              let inputTex = CVMetalTextureGetTexture(cvTex)
        else { return }

        // Compute target size & blit crop/offset for Fit / Fill (16:10 stretch) / Zoom.
        let (targetW, targetH): (Int, Int)
        switch mode {
        case .fit:
            let scale = min(Double(dstW) / Double(srcW), Double(dstH) / Double(srcH))
            targetW = max(1, Int((Double(srcW) * scale).rounded()))
            targetH = max(1, Int((Double(srcH) * scale).rounded()))
        case .fill:
            targetW = dstW
            targetH = dstH
        case .zoom:
            let scale = max(Double(dstW) / Double(srcW), Double(dstH) / Double(srcH))
            targetW = max(dstW, Int((Double(srcW) * scale).rounded()))
            targetH = max(dstH, Int((Double(srcH) * scale).rounded()))
        }

        let isDownscaling = (targetW < srcW || targetH < srcH)
        let renderTexture: MTLTexture

        if isDownscaling {
            // Downscaling: bypass spatial scaler to avoid unsupported downscaling crash / nil scaler
            renderTexture = inputTex
        } else {
            let key = "\(srcW)x\(srcH)->\(targetW)x\(targetH)"
            if key != scalerKey {
                scalerKey = key
                let desc = MTLFXSpatialScalerDescriptor()
                desc.inputWidth = srcW
                desc.inputHeight = srcH
                desc.outputWidth = targetW
                desc.outputHeight = targetH
                desc.colorTextureFormat = .bgra8Unorm
                desc.outputTextureFormat = .bgra8Unorm
                desc.colorProcessingMode = .perceptual
                scaler = desc.makeSpatialScaler(device: device)

                if scaler != nil {
                    let texDesc = MTLTextureDescriptor.texture2DDescriptor(
                        pixelFormat: .bgra8Unorm,
                        width: targetW,
                        height: targetH,
                        mipmapped: false
                    )
                    texDesc.usage = [.shaderWrite, .shaderRead, .renderTarget]
                    texDesc.storageMode = .private
                    upscaledTexture = device.makeTexture(descriptor: texDesc)
                } else {
                    upscaledTexture = nil
                }
            }

            guard let scaler, let upscaledTexture else { return }

            scaler.colorTexture = inputTex
            scaler.outputTexture = upscaledTexture
            scaler.encode(commandBuffer: commandBuffer)
            renderTexture = upscaledTexture
        }

        let renderedW = renderTexture.width
        let renderedH = renderTexture.height

        if mode == .fit, let rpd = view.currentRenderPassDescriptor {
            if let clearEnc = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) {
                clearEnc.endEncoding()
            }
            if let blit = commandBuffer.makeBlitCommandEncoder() {
                let ox = max(0, (dstW - renderedW) / 2)
                let oy = max(0, (dstH - renderedH) / 2)
                blit.copy(
                    from: renderTexture,
                    sourceSlice: 0,
                    sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                    sourceSize: MTLSize(width: min(renderedW, dstW), height: min(renderedH, dstH), depth: 1),
                    to: drawable.texture,
                    destinationSlice: 0,
                    destinationLevel: 0,
                    destinationOrigin: MTLOrigin(x: ox, y: oy, z: 0)
                )
                blit.endEncoding()
            }
        } else if let blit = commandBuffer.makeBlitCommandEncoder() {
            let sx = max(0, (renderedW - dstW) / 2)
            let sy = max(0, (renderedH - dstH) / 2)
            blit.copy(
                from: renderTexture,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: sx, y: sy, z: 0),
                sourceSize: MTLSize(width: min(renderedW, dstW), height: min(renderedH, dstH), depth: 1),
                to: drawable.texture,
                destinationSlice: 0,
                destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
            blit.endEncoding()
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
