import AirScan
import Darwin
import Foundation

@main
struct AirScanDiagnose {
  static func main() async {
    do {
      try await run()
    } catch {
      let message = "Diagnose fehlgeschlagen: \(String(reflecting: error))\n"
      FileHandle.standardError.write(Data(message.utf8))
      exit(1)
    }
  }

  private static func run() async throws {
    let arguments = Array(CommandLine.arguments.dropFirst())

    guard arguments.count == 2 else {
      FileHandle.standardError.write(Data("""
        Verwendung:
          airscan-diagnose <eSCL-Basis-URL> <XML-Ausgabedatei>

        Beispiel:
          airscan-diagnose http://192.168.133.14/eSCL/ /tmp/canon-capabilities.xml

        """.utf8))
      exit(2)
    }

    guard let url = URL(string: arguments[0]) else {
      throw DiagnosticError.invalidURL
    }

    let endpoint = try ScannerEndpoint(resourceRoot: url)
    let output = URL(fileURLWithPath: arguments[1])
    let transport = SavingTransport(output: output)
    let client = CapabilitiesClient(transport: transport)

    print("Abruf: \(endpoint.capabilitiesURL.absoluteString)")
    print("Verbindung: \(endpoint.isEncrypted ? "HTTPS" : "HTTP, unverschlüsselt")")
    print("XML-Ausgabedatei: \(output.path)")
    print("Es wird kein Scan-Auftrag erstellt.")

    let capabilities = try await client.fetch(from: endpoint)

    print("\nModell: \(capabilities.makeAndModel ?? "Nicht angegeben")")
    print("Erkannte Quellen: \(capabilities.inputs.count)")

    for input in capabilities.inputs {
      print("\nQuelle: \(input.source.rawValue)")
      print("  Breite min/max: \(text(input.minWidth)) / \(text(input.maxWidth))")
      print("  Höhe min/max: \(text(input.minHeight)) / \(text(input.maxHeight))")
      print("  Abmessungen in Einheiten von 1/300 Zoll")
      print("  Profile: \(input.profiles.count)")

      for (index, profile) in input.profiles.enumerated() {
        print("  Profil \(index + 1):")
        print("    Farbmodi: \(list(profile.colorModes))")
        print("    Formate: \(list(profile.documentFormats))")

        let resolutions = profile.resolutions.map { "\($0.x)x\($0.y)" }
        print("    Auflösungen: \(list(resolutions)) dpi")
      }
    }

    print("\nErkannte globale Einstellbereiche:")

    var adjustmentCount = 0
    for adjustment in ScannerCapabilities.Adjustment.allCases {
      guard let range = capabilities.adjustments[adjustment] else {
        continue
      }
      adjustmentCount += 1
      print("""
        \(adjustment.rawValue): \
        min=\(range.minimum), max=\(range.maximum), \
        normal=\(text(range.normal)), step=\(text(range.step))
        """)
    }

    if adjustmentCount == 0 {
      print("  Keine vom aktuellen Parser erkannt.")
    }

    if capabilities.inputs.isEmpty {
      print("\nHinweis: Keine Quellen erkannt; XML muss untersucht werden.")
    }

    print("\nFähigkeitenabruf und Parsing abgeschlossen.")
    print("Dies bestätigt noch nicht, dass Scannen funktioniert.")
  }

  private static func text(_ value: Int?) -> String {
    value.map { String($0) } ?? "nicht angegeben"
  }

  private static func list(_ values: [String]) -> String {
    values.isEmpty ? "nicht erkannt" : values.joined(separator: ", ")
  }
}

private enum DiagnosticError: Error {
  case invalidURL
}

private struct SavingTransport: ScannerHTTPTransport {
  let output: URL

  func get(_ url: URL) async throws -> ScannerHTTPResponse {
    let response = try await URLSessionScannerTransport().get(url)

    if response.statusCode == 200 {
      try response.body.write(to: output, options: .atomic)
    }

    return response
  }
}
