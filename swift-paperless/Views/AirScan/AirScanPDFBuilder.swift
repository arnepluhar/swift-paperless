import CoreGraphics
import Foundation
import ImageIO

enum AirScanPDFError: Error {
  case invalidConfiguration
  case unreadablePage(Int)
  case invalidImageSize(Int)
  case cannotCreatePDF
  case emptyPDF
}

@MainActor
enum AirScanPDFBuilder {
  static func build(
    directory: URL,
    pageCount: Int,
    resolution: Int
  ) async throws -> URL {
    try await AirScanPDFWorker().build(
      directory: directory,
      pageCount: pageCount,
      resolution: resolution
    )
  }
}

private actor AirScanPDFWorker {
  func build(
    directory: URL,
    pageCount: Int,
    resolution: Int
  ) async throws -> URL {
    guard (1...100).contains(pageCount), resolution > 0 else {
      throw AirScanPDFError.invalidConfiguration
    }
    try Task.checkCancellation()

    let destination = directory.appendingPathComponent("scan.pdf")
    let temporary = directory.appendingPathComponent(
      "scan-\(UUID().uuidString).partial.pdf"
    )
    defer { try? FileManager.default.removeItem(at: temporary) }

    var defaultBounds = CGRect(x: 0, y: 0, width: 1, height: 1)
    guard let consumer = CGDataConsumer(url: temporary as CFURL),
          let context = CGContext(
            consumer: consumer, mediaBox: &defaultBounds, nil
          ) else {
      throw AirScanPDFError.cannotCreatePDF
    }
    var closed = false
    defer {
      if !closed { context.closePDF() }
    }

    for number in 1...pageCount {
      try Task.checkCancellation()
      try autoreleasepool {
        let filename = String(format: "page-%04d.jpg", number)
        let sourceURL = directory.appendingPathComponent(filename)
        guard let source = CGImageSourceCreateWithURL(
          sourceURL as CFURL,
          [kCGImageSourceShouldCache: false] as CFDictionary
        ), let properties = CGImageSourceCopyPropertiesAtIndex(
          source, 0, nil
        ) as? [CFString: Any],
          let widthValue = properties[kCGImagePropertyPixelWidth] as? NSNumber,
          let heightValue = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
          throw AirScanPDFError.unreadablePage(number)
        }

        let sourceWidth = widthValue.intValue
        let sourceHeight = heightValue.intValue
        guard sourceWidth > 0, sourceHeight > 0,
              sourceWidth <= 100_000_000 / sourceHeight else {
          throw AirScanPDFError.invalidImageSize(number)
        }

        // Decode at original pixel dimensions while applying EXIF orientation.
        let options: [CFString: Any] = [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: max(sourceWidth, sourceHeight),
          kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
          source, 0, options as CFDictionary
        ) else {
          throw AirScanPDFError.unreadablePage(number)
        }
        try Task.checkCancellation()

        let width = CGFloat(image.width) * 72 / CGFloat(resolution)
        let height = CGFloat(image.height) * 72 / CGFloat(resolution)
        guard width.isFinite, height.isFinite, width > 0, height > 0 else {
          throw AirScanPDFError.invalidImageSize(number)
        }

        var bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let boxData = NSData(bytes: &bounds, length: MemoryLayout<CGRect>.size)
        let pageInfo = [kCGPDFContextMediaBox: boxData] as CFDictionary
        context.beginPDFPage(pageInfo)
        context.draw(image, in: bounds)
        context.endPDFPage()
      }
      await Task.yield()
    }

    try Task.checkCancellation()
    context.closePDF()
    closed = true
    try Task.checkCancellation()

    let attributes = try FileManager.default.attributesOfItem(atPath: temporary.path)
    guard let size = attributes[.size] as? NSNumber, size.int64Value > 0 else {
      throw AirScanPDFError.emptyPDF
    }
    try FileManager.default.moveItem(at: temporary, to: destination)
    return destination
  }
}
