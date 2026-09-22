import CoreImage
import CoreVideo
import DictationCore
import Foundation

/// One reusable GPU context and a bounded pixel-buffer pool per recording.
/// Only the media queue may use this object.
final class ScreenFrameCompositor {
    private let context = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])
    private let width: Int
    private let height: Int
    private let pool: CVPixelBufferPool

    init(width: Int, height: Int) throws {
        self.width = width
        self.height = height
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        var created: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &created) == kCVReturnSuccess,
              let created else { throw ScreenRecordingError.writerUnavailable }
        pool = created
    }

    func frame(screen: CVPixelBuffer, camera: CVPixelBuffer?, scale: Double, position: NormalizedPoint) -> CVPixelBuffer? {
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        var image = Self.fitted(CIImage(cvPixelBuffer: screen), to: canvas)
        if let camera {
            let bubble = ScreenBubbleGeometry.rect(in: canvas.size, scale: scale, position: position)
            let source = Self.mirrored(CIImage(cvPixelBuffer: camera))
            if source.extent.width > 0, source.extent.height > 0 {
                let cover = max(bubble.width / source.extent.width, bubble.height / source.extent.height)
                let scaled = source.transformed(by: CGAffineTransform(scaleX: cover, y: cover))
                let crop = CGRect(x: scaled.extent.midX - bubble.width / 2,
                                  y: scaled.extent.midY - bubble.height / 2,
                                  width: bubble.width, height: bubble.height)
                let cameraImage = scaled.cropped(to: crop).transformed(by: CGAffineTransform(
                    translationX: bubble.minX - crop.minX, y: bubble.minY - crop.minY
                ))
                if let mask = CIFilter(name: "CIRadialGradient", parameters: [
                    "inputCenter": CIVector(x: bubble.midX, y: bubble.midY),
                    "inputRadius0": max(0, bubble.width / 2 - 1),
                    "inputRadius1": bubble.width / 2,
                    "inputColor0": CIColor.white,
                    "inputColor1": CIColor.clear,
                ])?.outputImage?.cropped(to: canvas) {
                    image = cameraImage.applyingFilter("CIBlendWithMask", parameters: [
                        kCIInputBackgroundImageKey: image,
                        kCIInputMaskImageKey: mask,
                    ]).cropped(to: canvas)
                }
            }
        }
        var output: CVPixelBuffer?
        let limits = [kCVPixelBufferPoolAllocationThresholdKey as String: 8] as CFDictionary
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, limits, &output) == kCVReturnSuccess,
              let output else { return nil }
        context.render(image, to: output)
        return output
    }

    private static func fitted(_ image: CIImage, to canvas: CGRect) -> CIImage {
        guard image.extent.width > 0, image.extent.height > 0 else {
            return CIImage(color: .black).cropped(to: canvas)
        }
        let factor = min(canvas.width / image.extent.width, canvas.height / image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        return scaled.transformed(by: CGAffineTransform(
            translationX: canvas.midX - scaled.extent.midX,
            y: canvas.midY - scaled.extent.midY
        )).composited(over: CIImage(color: .black).cropped(to: canvas)).cropped(to: canvas)
    }

    private static func mirrored(_ image: CIImage) -> CIImage {
        let width = image.extent.width
        return image.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -width, y: 0))
    }
}
