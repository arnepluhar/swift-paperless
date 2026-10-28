import AirScan
import Foundation
import SwiftUI

@MainActor
final class AirScanScannerModel: ObservableObject {
  @Published private(set) var capabilities: ScannerCapabilities?
  @Published private(set) var status: ScannerStatus?
  @Published private(set) var isBusy = false
  @Published private(set) var errorMessage: String?
  @Published private(set) var events: [String] = []

  private var endpoint: ScannerEndpoint?
  private var work: Task<Void, Never>?

  var isConnected: Bool {
    endpoint != nil && capabilities != nil
  }

  func connect(address: String) {
    guard !isBusy else { return }

    capabilities = nil
    status = nil
    endpoint = nil

    start {
      let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)

      guard let url = URL(string: trimmed) else {
        throw ScannerEndpoint.ValidationError.invalidURL
      }

      let candidate = try ScannerEndpoint(resourceRoot: url)

      self.record("Fähigkeitenabruf gestartet.")
      let capabilities = try await CapabilitiesClient().fetch(from: candidate)
      try Task.checkCancellation()

      self.endpoint = candidate
      self.capabilities = capabilities
      self.record(
        "Fähigkeiten geladen; \(capabilities.inputs.count) Quellen erkannt."
      )

      // A status failure must not discard successfully loaded capabilities.
      do {
        let status = try await ScannerStatusClient().fetch(from: candidate)
        try Task.checkCancellation()
        self.status = status
        self.record("Scannerstatus geladen.")
      } catch {
        try Task.checkCancellation()
        self.errorMessage = Self.message(for: error)
        self.record("Statusabruf fehlgeschlagen; Fähigkeiten bleiben verfügbar.")
      }
    }
  }

  func refreshStatus() {
    guard !isBusy, let endpoint else { return }

    start {
      self.record("Scannerstatus wird aktualisiert.")
      let status = try await ScannerStatusClient().fetch(from: endpoint)
      try Task.checkCancellation()
      self.status = status
      self.record("Scannerstatus aktualisiert.")
    }
  }

  func invalidateConnection() {
    guard !isBusy else { return }
    endpoint = nil
    capabilities = nil
    status = nil
    errorMessage = nil
  }

  func cancel() {
    work?.cancel()
  }

  func clearEvents() {
    events.removeAll()
  }

  var debugReport: String {
    var lines = [
      "Swift Paperless – AirScan-Diagnose",
      "Stand: App-Integration in Entwicklung",
      "Keine automatische Übertragung dieses Berichts.",
      ""
    ]

    if let capabilities {
      lines.append("Modell: \(capabilities.makeAndModel ?? "nicht angegeben")")

      for input in capabilities.inputs {
        lines.append("Quelle: \(input.source.rawValue)")
        lines.append("Profile: \(input.profiles.count)")
        lines.append("Intents: \(input.supportedIntents.joined(separator: ", "))")

        for (index, profile) in input.profiles.enumerated() {
          lines.append("  Profil \(index + 1)")
          lines.append("  Farben: \(profile.colorModes.joined(separator: ", "))")
          lines.append("  Formate: \(profile.documentFormats.joined(separator: ", "))")

          let resolutions = profile.resolutions.map { "\($0.x)x\($0.y)" }
          lines.append("  Auflösungen: \(resolutions.joined(separator: ", "))")
          lines.append(
            "  Inhaltsarten: \(profile.contentTypes.joined(separator: ", "))"
          )
        }
      }

      for adjustment in ScannerCapabilities.Adjustment.allCases {
        guard let range = capabilities.adjustments[adjustment] else { continue }
        lines.append(
          "\(adjustment.rawValue): \(range.minimum)...\(range.maximum), "
          + "Standard \(range.normal.map { String($0) } ?? "unbekannt")"
        )
      }

      lines.append(
        "Leerseitenerkennung: \(Self.boolean(capabilities.blankPageDetection))"
      )
      lines.append(
        "Leerseitenentfernung: "
        + Self.boolean(capabilities.blankPageDetectionAndRemoval)
      )
    } else {
      lines.append("Keine Fähigkeiten geladen.")
    }

    if let status {
      lines.append("")
      lines.append("Scannerzustand: \(status.state ?? "nicht angegeben")")
      lines.append("Einzugszustand: \(status.adfState ?? "nicht angegeben")")
      lines.append("Jobs in Statusantwort: \(status.jobs.count)")
    }

    lines.append("")
    lines.append("Ablauf:")
    lines.append(contentsOf: events)

    return lines.joined(separator: "\n")
  }

  private func start(
    operation: @escaping @MainActor () async throws -> Void
  ) {
    isBusy = true
    errorMessage = nil

    work = Task { @MainActor in
      defer {
        self.isBusy = false
        self.work = nil
      }

      do {
        try await operation()
      } catch {
        if Task.isCancelled || error is CancellationError {
          self.record("Vorgang abgebrochen.")
        } else {
          self.errorMessage = Self.message(for: error)
          // Do not put raw URLs, XML, or complete error objects in the report.
          self.record("Vorgang fehlgeschlagen: \(String(describing: type(of: error))).")
        }
      }
    }
  }

  private func record(_ message: String) {
    events.append(message)
    if events.count > 150 {
      events.removeFirst(events.count - 150)
    }
  }

  private static func boolean(_ value: Bool?) -> String {
    guard let value else { return "nicht angegeben" }
    return value ? "ja" : "nein"
  }

  private static func message(for error: Error) -> String {
    if let statusError = error as? ScannerStatusError {
      switch statusError {
      case .paperJam:
        return "Papierstau im Dokumenteneinzug. Bitte am Gerät beheben."
      case .feederEmpty:
        return "Der Dokumenteneinzug ist leer."
      case .scannerNotIdle(let state):
        return "Der Scanner ist nicht bereit. Zustand: \(state)"
      case .feederNotReady(let state):
        return "Der Dokumenteneinzug ist nicht bereit. Zustand: \(state)"
      default:
        break
      }
    }

    if let urlError = error as? URLError {
      switch urlError.code {
      case .timedOut:
        return "Der Scanner hat nicht rechtzeitig geantwortet."
      case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost:
        return "Scanner nicht erreichbar. Adresse, WLAN und Netzwerkzugriff prüfen."
      case .cancelled:
        return "Vorgang abgebrochen."
      default:
        return "Netzwerkfehler: \(urlError.code.rawValue)"
      }
    }

    return String(describing: error)
  }
}
