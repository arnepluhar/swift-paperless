import AirScan
import AppKit
import Darwin
import Foundation
import ImageIO
import PDFKit

@main
struct AirScanScanFeeder {
  static func main() async {
    do {
      try await run()
    } catch {
      writeError("Einzugstest fehlgeschlagen: \(String(reflecting: error))")
      writeError("Bereits gespeicherte Seiten bleiben im Ausgabeverzeichnis.")
      exit(1)
    }
  }

  private static func run() async throws {
    let arguments = Array(CommandLine.arguments.dropFirst())

    guard arguments.count == 4,
          arguments[0] == "--simplex",
          let expectedPages = Int(arguments[2]),
          (1...20).contains(expectedPages) else {
      writeError("""
        Verwendung:
          airscan-scan-feeder --simplex <eSCL-URL> <Seitenzahl> <neuer Ausgabeordner>

        Startet einen echten Einzugsscan: Farbe, 150 dpi, JPEG-Seiten.
        """)
      exit(2)
    }

    guard let url = URL(string: arguments[1]) else {
      throw ToolError.invalidURL
    }

    let directory = URL(fileURLWithPath: arguments[3], isDirectory: true)

    guard !FileManager.default.fileExists(atPath: directory.path) else {
      throw ToolError.outputAlreadyExists
    }

    let endpoint = try ScannerEndpoint(resourceRoot: url)
    let capabilities = try await CapabilitiesClient().fetch(from: endpoint)

    guard let input = capabilities.inputs.first(where: {
      $0.source == .feederSimplex
    }), let width = input.maxWidth else {
      throw ToolError.missingFeederWidth
    }

    let height = 3508

    let settings = ScanSettings(
      source: .feederSimplex,
      colorMode: .color,
      documentFormat: .jpeg,
      resolution: 150,
      width: width,
      height: height
    )

    _ = try settings.xml(validating: capabilities)

    let statusClient = ScannerStatusClient()
    let before = try await statusClient.fetch(from: endpoint)

    print("Vorprüfung: Scanner=\(before.state ?? "?"), Einzug=\(before.adfState ?? "?")")
    try before.requireFeederReady()

    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: false
    )

    let writer = PageWriter(directory: directory)
    let client = ScanJobClient(
      endpoint: endpoint,
      transport: TracingFeederTransport(
        endpoint: endpoint,
        directory: directory
      )
    )

    print("Starte echten SIMPLEX-Einzugsscan.")
    print("Erwartete Seiten: \(expectedPages)")
    print("Scanbereich: \(width) x \(height), Einheiten 1/300 Zoll")
    print("Ausgabe: \(directory.path)")

    let result = try await FeederScan.run(
      client: client,
      settings: settings,
      capabilities: capabilities,
      expectedPages: expectedPages,
      verifyCompletion: { job, count in
        let status = try await statusClient.fetch(from: endpoint)

        try status.requireCompleted(
          jobURL: job.url,
          resourceRoot: endpoint.resourceRoot,
          receivedPages: count
        )

        print("Passender Job abgeschlossen; \(count) Bilder vom Scanner bestätigt.")
      }
    ) { document, index in
      try await writer.save(document, index: index)
    }

    if let warning = result.cleanupWarning {
      writeError("WARNUNG beim Aufräumen: \(warning)")
    }

    let output = try assemblePDF(
      directory: directory,
      count: result.pageCount,
      width: width,
      height: height
    )

    print("PDF erstellt: \(output.path)")
    print("Seiten: \(result.pageCount)")
    print("Seitenreihenfolge bitte anhand der gedruckten Kennungen prüfen.")

    if result.cleanupWarning != nil {
      exit(3)
    }

    print("Job-Löschung bestätigt oder Job bereits entfernt.")
  }

  private static func assemblePDF(
    directory: URL,
    count: Int,
    width: Int,
    height: Int
  ) throws -> URL {
    let pdf = PDFDocument()

    for index in 1...count {
      let url = directory.appendingPathComponent(
        String(format: "page-%03d.jpg", index)
      )

      guard let image = NSImage(contentsOf: url) else {
        throw ToolError.invalidImage
      }

      image.size = NSSize(
        width: Double(width) * 72.0 / 300.0,
        height: Double(height) * 72.0 / 300.0
      )

      guard let page = PDFPage(image: image) else {
        throw ToolError.invalidImage
      }

      pdf.insert(page, at: pdf.pageCount)
    }

    guard pdf.pageCount == count, let data = pdf.dataRepresentation() else {
      throw ToolError.pdfAssemblyFailed
    }

    let output = directory.appendingPathComponent("combined.pdf")
    try data.write(to: output, options: .withoutOverwriting)
    return output
  }

  private static func writeError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
  }
}

private actor PageWriter {
  let directory: URL

  init(directory: URL) {
    self.directory = directory
  }

  func save(_ document: ScannedDocument, index: Int) throws {
    // Save first, so even an unexpected response body remains inspectable.
    let raw = directory.appendingPathComponent(
      String(format: "page-%03d.received", index)
    )
    try document.data.write(to: raw, options: .withoutOverwriting)

    guard document.data.starts(with: [0xFF, 0xD8]),
          let source = CGImageSourceCreateWithData(
            document.data as CFData,
            nil
          ),
          CGImageSourceGetCount(source) == 1,
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
      throw ToolError.invalidImage
    }

    let destination = directory.appendingPathComponent(
      String(format: "page-%03d.jpg", index)
    )
    try FileManager.default.moveItem(at: raw, to: destination)

    print(
      "Seite \(index) gespeichert: \(image.width) x \(image.height) Pixel, "
      + "\(document.data.count) Bytes"
    )
  }
}

private enum ToolError: Error {
  case invalidURL
  case outputAlreadyExists
  case missingFeederWidth
  case invalidImage
  case pdfAssemblyFailed
}

private struct TracingFeederTransport: ScanJobTransport {
  let endpoint: ScannerEndpoint
  let directory: URL

  func send(_ request: URLRequest) async throws -> ScanJobHTTPResponse {
    let method = request.httpMethod ?? "GET"
    let address = request.url?.absoluteString ?? "?"

    if method == "POST" {
      if let body = request.httpBody {
        try body.write(
          to: directory.appendingPathComponent("request-settings.xml"),
          options: .atomic
        )
      }
      await saveStatus(name: "status-before-create.xml")
    }

    print("HTTP >>> \(method) \(address)")

    let response: ScanJobHTTPResponse

    do {
      response = try await URLSessionScanJobTransport().send(request)
    } catch {
      print("HTTP !!! \(String(reflecting: error))")
      throw error
    }

    print("HTTP <<< \(response.statusCode), \(response.body.count) Bytes")

    if let location = response.location {
      print("Location: \(location)")
    }

    if let contentType = response.contentType {
      print("Content-Type: \(contentType)")
    }

    if !(200...299).contains(response.statusCode) {
      let output = directory.appendingPathComponent(
        "response-\(method)-\(response.statusCode).body"
      )

      do {
        try response.body.write(to: output, options: .atomic)
        print("Fehlerantwort gespeichert: \(output.path)")
      } catch {
        print("Warnung: Fehlerantwort konnte nicht gespeichert werden: \(error)")
      }

      if method == "GET" {
        await saveStatus(name: "status-after-read-error.xml")
      }
    }

    return response
  }

  private func saveStatus(name: String) async {
    do {
      let response = try await URLSessionScannerTransport().get(
        endpoint.statusURL
      )
      let output = directory.appendingPathComponent(name)

      try response.body.write(to: output, options: .atomic)

      print("ScannerStatus HTTP \(response.statusCode): \(output.path)")
    } catch {
      print("ScannerStatus nicht verfügbar: \(String(reflecting: error))")
    }
  }
}
