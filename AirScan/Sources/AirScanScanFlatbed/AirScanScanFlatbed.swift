import AirScan
import Darwin
import Foundation
import ImageIO
import PDFKit

@main
struct AirScanScanFlatbed {
  static func main() async {
    do {
      try await run()
    } catch {
      writeError("Scan fehlgeschlagen: \(String(reflecting: error))")
      exit(1)
    }
  }

  private static func run() async throws {
    let arguments = Array(CommandLine.arguments.dropFirst())

    guard arguments.count == 3, arguments[0] == "--scan" else {
      writeError("""
        Verwendung:
          airscan-scan-flatbed --scan <eSCL-Basis-URL> <Ausgabedatei.jpg|pdf>

        ACHTUNG: Startet einen echten Flachbett-Scan.
        Einstellungen: Farbe, 150 dpi, Bereich 2480 x 3508.
        Das Ausgabeformat wird anhand der Dateiendung gewählt.
        """)
      exit(2)
    }

    guard let url = URL(string: arguments[1]) else {
      throw ToolError.invalidURL
    }

    let output = URL(fileURLWithPath: arguments[2])
    let format: ScanSettings.DocumentFormat

    switch output.pathExtension.lowercased() {
    case "jpg", "jpeg":
      format = .jpeg
    case "pdf":
      format = .pdf
    default:
      throw ToolError.unsupportedOutputExtension
    }

    guard !FileManager.default.fileExists(atPath: output.path) else {
      throw ToolError.outputAlreadyExists
    }

    let parent = output.deletingLastPathComponent()
    var isDirectory: ObjCBool = false

    guard FileManager.default.fileExists(
      atPath: parent.path,
      isDirectory: &isDirectory
    ), isDirectory.boolValue else {
      throw ToolError.outputDirectoryMissing
    }

    let endpoint = try ScannerEndpoint(resourceRoot: url)

    print("Fähigkeiten abrufen: \(endpoint.capabilitiesURL.absoluteString)")
    let capabilities = try await CapabilitiesClient().fetch(from: endpoint)

    let settings = ScanSettings(
      source: .platen,
      colorMode: .color,
      documentFormat: format,
      resolution: 150,
      width: 2480,
      height: 3508
    )

    _ = try settings.xml(validating: capabilities)

    let client = ScanJobClient(
      endpoint: endpoint,
      transport: URLSessionScanJobTransport()
    )

    print("Starte echten Flachbett-Scan: Farbe, 150 dpi, \(format.rawValue).")
    print("Keine automatischen Wiederholungen.")

    let result = try await FlatbedScan.run(
      client: client,
      settings: settings,
      capabilities: capabilities
    )

    if let warning = result.cleanupWarning {
      writeError("WARNUNG beim Aufräumen: \(warning)")
    }

    let data = result.document.data

    switch format {
    case .jpeg:
      guard data.starts(with: [0xFF, 0xD8]),
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetCount(source) == 1,
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw ToolError.invalidJPEG
      }

      print("Bildgröße: \(image.width) x \(image.height) Pixel")

    case .pdf:
      guard data.starts(with: Array("%PDF-".utf8)),
            let pdf = PDFDocument(data: data),
            !pdf.isLocked,
            pdf.pageCount == 1,
            let page = pdf.page(at: 0) else {
        throw ToolError.invalidSinglePagePDF
      }

      let bounds = page.bounds(for: .mediaBox)
      let text = (pdf.string ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)

      print("PDF-Seiten: \(pdf.pageCount)")
      print("Seitengröße: \(bounds.width) x \(bounds.height) PDF-Punkte")
      print("Extrahierbare Textzeichen: \(text.count)")

      if text.isEmpty {
        print("Keine mit PDFKit extrahierbare Textebene erkannt.")
      } else {
        print("Extrahierbarer Text vorhanden; bitte Qualität im PDF prüfen.")
      }
    }

    try data.write(to: output, options: .withoutOverwriting)

    print("Gespeichert: \(output.path)")
    print("Empfangen: \(data.count) Bytes")
    print("Content-Type: \(result.document.contentType ?? "nicht angegeben")")

    if result.cleanupWarning == nil {
      print("Job-Löschung bestätigt oder Job bereits entfernt.")
    } else {
      writeError("Datei gespeichert, aber vor einem weiteren Scan den Jobzustand prüfen.")
      exit(3)
    }
  }

  private static func writeError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
  }
}

private enum ToolError: Error {
  case invalidURL
  case unsupportedOutputExtension
  case outputAlreadyExists
  case outputDirectoryMissing
  case invalidJPEG
  case invalidSinglePagePDF
}
