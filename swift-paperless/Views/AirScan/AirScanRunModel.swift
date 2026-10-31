import AirScan
import Foundation
import SwiftUI

private actor AirScanPageStore {
  let directory: URL

  init(directory: URL) {
    self.directory = directory
  }

  func save(_ document: ScannedDocument, number: Int) throws {
    // Check the payload instead of trusting only the HTTP content type.
    guard document.data.starts(with: [0xFF, 0xD8, 0xFF]) else {
      throw AirScanRunError.invalidJPEG
    }

    let name = String(format: "page-%04d.jpg", number)
    try document.data.write(
      to: directory.appendingPathComponent(name),
      options: .atomic
    )
  }
}

private enum AirScanRunError: LocalizedError {
  case invalidJPEG

  var errorDescription: String? {
    switch self {
    case .invalidJPEG:
      "Der Scanner hat keine erkennbare JPEG-Seite geliefert."
    }
  }
}

@MainActor
final class AirScanRunModel: ObservableObject {
  @Published private(set) var isBusy = false
  @Published private(set) var receivedPages = 0
  @Published private(set) var message: String?
  @Published private(set) var errorMessage: String?
  @Published private(set) var cleanupWarning = false
  @Published private(set) var completed = false
  @Published private(set) var directory: URL?
  @Published private(set) var pdfURL: URL?

  private var work: Task<Void, Never>?

  func start(
    address: String,
    settings: ScanSettings,
    capabilities: ScannerCapabilities,
    expectedPages: Int
  ) {
    guard !isBusy else { return }

    isBusy = true
    receivedPages = 0
    message = "Scan wird vorbereitet …"
    errorMessage = nil
    cleanupWarning = false
    completed = false
    directory = nil
    pdfURL = nil

    work = Task { @MainActor in
      defer {
        self.isBusy = false
        self.work = nil
      }

      do {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
          throw ScannerEndpoint.ValidationError.invalidURL
        }

        let endpoint = try ScannerEndpoint(resourceRoot: url)
        _ = try settings.xml(validating: capabilities)
        try Task.checkCancellation()

        if settings.source != .platen {
          let status = try await ScannerStatusClient().fetch(from: endpoint)
          try status.requireFeederReady()
        }

        try Task.checkCancellation()

        let root = try FileManager.default.url(
          for: .applicationSupportDirectory,
          in: .userDomainMask,
          appropriateFor: nil,
          create: true
        )
        let directory = root
          .appendingPathComponent("AirScan", isDirectory: true)
          .appendingPathComponent(UUID().uuidString, isDirectory: true)

        try FileManager.default.createDirectory(
          at: directory,
          withIntermediateDirectories: true
        )

        self.directory = directory
        let store = AirScanPageStore(directory: directory)
        let client = ScanJobClient(
          endpoint: endpoint,
          transport: URLSessionScanJobTransport()
        )

        self.message = "Scan läuft …"

        if settings.source == .platen {
          let result = try await FlatbedScan.run(
            client: client,
            settings: settings,
            capabilities: capabilities
          )

          // Preserve a received page even if cancellation arrived during cleanup.
          try await store.save(result.document, number: 1)
          self.receivedPages = 1
          self.cleanupWarning = result.cleanupWarning != nil
        } else {
          let result = try await FeederScan.run(
            client: client,
            settings: settings,
            capabilities: capabilities,
            expectedPages: expectedPages,
            verifyCompletion: { job, count in
              let status = try await ScannerStatusClient().fetch(from: endpoint)
              try status.requireCompleted(
                jobURL: job.url,
                resourceRoot: endpoint.resourceRoot,
                receivedPages: count
              )
            },
            receivePage: { [weak self] document, number in
              try await store.save(document, number: number)
              await self?.pageSaved(number)
            }
          )

          self.cleanupWarning = result.cleanupWarning != nil
        }

        try Task.checkCancellation()
        self.completed = true
        self.message = "Scan bestätigt. PDF wird erstellt …"

        do {
          let pdf = try await AirScanPDFBuilder.build(
            directory: directory,
            pageCount: self.receivedPages,
            resolution: settings.resolution
          )
          try Task.checkCancellation()
          self.pdfURL = pdf
          self.message =
            "Scan abgeschlossen. PDF mit \(self.receivedPages) Seite(n) erstellt."
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          try Task.checkCancellation()
          self.message =
            "Scan bestätigt; die Bildseiten bleiben lokal gespeichert."
          self.errorMessage =
            "Das PDF konnte nicht erstellt werden. "
            + "Die gespeicherten JPEG-Seiten bleiben erhalten."
        }
      } catch {
        if Task.isCancelled || error is CancellationError {
          self.message =
            "Abgebrochen. \(self.receivedPages) bereits gespeicherte Bildseite(n) bleiben erhalten."
          // A workflow error can also contain a failed cleanup.
          if !(error is CancellationError),
             (error as? URLError)?.code != .cancelled {
            self.errorMessage =
              "Beim Abbruch wurde zusätzlich ein Fehler gemeldet. "
              + "Scannerzustand vor einem erneuten Start prüfen."
          }
        } else {
          self.message =
            "Scan nicht bestätigt. \(self.receivedPages) gespeicherte Bildseite(n) bleiben erhalten."
          self.errorMessage = Self.message(for: error)
        }
      }
    }
  }

  func cancel() {
    guard isBusy else { return }
    message = "Abbruch angefordert; laufende Verarbeitung wird beendet …"
    work?.cancel()
  }

  private func pageSaved(_ number: Int) {
    receivedPages = number
    message = "\(number) Bildseite(n) gespeichert …"
  }

  private static func message(for error: Error) -> String {
    if let statusError = error as? ScannerStatusError {
      switch statusError {
      case .paperJam:
        return "Papierstau. Bitte am Scanner beheben."
      case .feederEmpty:
        return "Der Dokumenteneinzug ist leer."
      case .scannerNotIdle:
        return "Der Scanner ist nicht bereit."
      case .feederNotReady:
        return "Der Dokumenteneinzug ist nicht bereit."
      case .completionNotConfirmed:
        return "Der Scanner hat den vollständigen Abschluss nicht bestätigt."
      default:
        return "Der Scannerstatus konnte nicht zuverlässig geprüft werden."
      }
    }

    if let feederError = error as? FeederScanError {
      switch feederError {
      case .invalidConfiguration:
        return "Die Einzugseinstellungen sind ungültig."
      case .unexpectedPageCount(let expected, let received):
        return "Abweichende Seitenzahl: erwartet \(expected), empfangen \(received)."
      case .scanAndCleanupFailed:
        return "Scan und Aufräumen des Geräteauftrags sind fehlgeschlagen."
      }
    }

    if let flatbedError = error as? FlatbedScanError {
      switch flatbedError {
      case .requiresFlatbedSource:
        return "Die ausgewählte Quelle ist kein Flachbett."
      case .noDocument:
        return "Der Scanner hat keine Seite geliefert."
      case .scanAndCleanupFailed:
        return "Scan und Aufräumen des Geräteauftrags sind fehlgeschlagen."
      }
    }

    if let localError = error as? AirScanRunError {
      return localError.localizedDescription
    }

    if error is URLError {
      return "Netzwerkfehler beim Scan. Scannerzustand vor erneutem Start prüfen."
    }

    if (error as NSError).domain == NSCocoaErrorDomain {
      return "Die Scandaten konnten lokal nicht gespeichert werden."
    }

    return "Der Scan ist fehlgeschlagen. Es erfolgt kein automatischer Neustart."
  }
}
