import Foundation
import UIKit

enum AirScanPDFError: Error {
  case invalidConfiguration
  case unreadablePage(Int)
  case invalidImageSize(Int)
  case emptyPDF
}

@MainActor
enum AirScanPDFBuilder {
  static func build(
    directory: URL,
    pageCount: Int,
    resolution: Int
  ) throws -> URL {
    guard (1...100).contains(pageCount), resolution > 0 else {
      throw AirScanPDFError.invalidConfiguration
    }

    let destination = directory.appendingPathComponent("scan.pdf")
    let temporary = directory.appendingPathComponent(
      "scan-\(UUID().uuidString).partial.pdf"
    )

    defer {
      try? FileManager.default.removeItem(at: temporary)
    }

    let renderer = UIGraphicsPDFRenderer(
      bounds: CGRect(x: 0, y: 0, width: 1, height: 1)
    )
    var pageError: AirScanPDFError?

    try renderer.writePDF(to: temporary) { context in
      for number in 1...pageCount {
        autoreleasepool {
          guard pageError == nil else { return }

          let filename = String(format: "page-%04d.jpg", number)
          let source = directory.appendingPathComponent(filename)

          guard let image = UIImage(contentsOfFile: source.path),
                image.cgImage != nil else {
            pageError = .unreadablePage(number)
            return
          }

          // UIImage's oriented size accounts for image orientation.
          // Convert pixel dimensions to PDF points using the selected dpi.
          let pixelWidth = image.size.width * image.scale
          let pixelHeight = image.size.height * image.scale
          let width = pixelWidth * 72 / CGFloat(resolution)
          let height = pixelHeight * 72 / CGFloat(resolution)

          guard width.isFinite, height.isFinite,
                width > 0, height > 0 else {
            pageError = .invalidImageSize(number)
            return
          }

          let bounds = CGRect(x: 0, y: 0, width: width, height: height)
          context.beginPage(withBounds: bounds, pageInfo: [:])
          image.draw(in: bounds)
        }

        if pageError != nil {
          break
        }
      }
    }

    if let pageError {
      throw pageError
    }

    let attributes = try FileManager.default.attributesOfItem(
      atPath: temporary.path
    )
    guard let size = attributes[.size] as? NSNumber,
          size.int64Value > 0 else {
      throw AirScanPDFError.emptyPDF
    }

    // Never replace an existing result silently.
    try FileManager.default.moveItem(
      at: temporary,
      to: destination
    )

    return destination
  }
}
