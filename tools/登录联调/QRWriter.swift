import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// 用 CoreImage 把二维码内容渲染成 PNG。
///
/// 与 App 内 LoginView.swift 用的是同一个 `CIFilter.qrCodeGenerator`，
/// 所以如果这里渲染出来的码扫不出来，那 App 里的码也扫不出来 —— 一致性保证。
enum QRWriter {
    /// 把字符串渲染成二维码 PNG。
    ///
    /// - Parameters:
    ///   - content: 二维码内容（优酷短链）
    ///   - path: 输出 PNG 路径
    ///   - scale: 每个模块的像素边长（默认 12，300px 的码大约 25x25 模块）
    static func write(content: String, to path: String, scale: Int = 12) throws {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(content.utf8)
        // 中等纠错级别，扫码器兼容性最好
        filter.correctionLevel = "M"

        guard let output = filter.outputImage else {
            throw NSError(domain: "QRWriter", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "CoreImage 无法生成二维码"
            ])
        }

        // CIImage 坐标系原点在左下，需要翻转成 PNG 的左上原点
        let scaleTransform = CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale))
        let scaled = output.transformed(by: scaleTransform)
        let context = CIContext(options: [.useSoftwareRenderer: false])

        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else {
            throw NSError(domain: "QRWriter", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "无法渲染 CIImage"
            ])
        }

        // 给二维码加一圈静区（白边），没有静区的码很多扫码器识别不到
        let quiet: CGFloat = 4 * CGFloat(scale)
        let finalImage = addQuietZone(to: cgImage, quiet: quiet)

        let url = URL(fileURLWithPath: path)
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw NSError(domain: "QRWriter", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "无法创建 PNG 文件：\(path)"
            ])
        }
        CGImageDestinationAddImage(dest, finalImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "QRWriter", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "PNG 写入失败：\(path)"
            ])
        }
    }

    /// 在二维码外围补白边（静区）。
    private static func addQuietZone(to image: CGImage, quiet: CGFloat) -> CGImage {
        let width = image.width + Int(quiet * 2)
        let height = image.height + Int(quiet * 2)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            return image
        }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.draw(image, in: CGRect(
            x: CGFloat(quiet), y: CGFloat(quiet),
            width: CGFloat(image.width), height: CGFloat(image.height)
        ))
        return ctx.makeImage() ?? image
    }
}
