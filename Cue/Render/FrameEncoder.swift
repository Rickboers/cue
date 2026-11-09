import CoreGraphics
import CoreMedia
import CoreVideo

/// Renders prompter frames into pixel buffers and wraps them as "show immediately" sample
/// buffers for the Picture-in-Picture display layer.
final class FrameEncoder {
    private var pool: CVPixelBufferPool?
    private var format: CMVideoFormatDescription?
    private var poolSize = (w: 0, h: 0)
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// `logicalSize` is the frame as you read it. `quarterTurn` (+1 / −1) turns it on its side for a
    /// phone held in landscape: +1 when the top of the phone is to your left. Pixel sizes are the
    /// buffer's, so they're already swapped for a turned frame.
    func makeSampleBuffer(pixelWidth: Int, pixelHeight: Int, logicalSize: CGSize, quarterTurn: Int = 0,
                          draw: (CGContext) -> Void) -> CMSampleBuffer? {
        let w = max(16, pixelWidth & ~1), h = max(16, pixelHeight & ~1)
        if pool == nil || poolSize.w != w || poolSize.h != h {
            makePool(w: w, h: h)
        }
        guard let pool else { return nil }
        var pb: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess, let buffer = pb else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }

        // Flip to a top-left origin and scale logical points to pixels.
        let screen = quarterTurn == 0 ? logicalSize : CGSize(width: logicalSize.height, height: logicalSize.width)
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: CGFloat(w) / screen.width, y: -CGFloat(h) / screen.height)
        if quarterTurn > 0 {
            // Your right is the screen's down, your down is the screen's left.
            ctx.concatenate(CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: screen.width, ty: 0))
        } else if quarterTurn < 0 {
            ctx.concatenate(CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: screen.height))
        }
        ctx.setShouldSmoothFonts(false)
        ctx.setAllowsFontSmoothing(false)
        draw(ctx)

        if format == nil {
            var desc: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &desc)
            format = desc
        }
        guard let format else { return nil }

        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: format,
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }

    private func makePool(w: Int, h: Int) {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        var p: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 3] as CFDictionary, attrs as CFDictionary, &p)
        pool = p
        format = nil
        poolSize = (w, h)
    }
}
