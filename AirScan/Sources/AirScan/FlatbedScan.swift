import Foundation

public enum FlatbedScanError: Error, Equatable, Sendable {
  case requiresFlatbedSource
  case noDocument
  case scanAndCleanupFailed(scan: String, cleanup: String)
}

public struct FlatbedScanResult: Sendable {
  public let document: ScannedDocument
  public let cleanupWarning: String?
}

public enum FlatbedScan {
  public static func run(
    client: ScanJobClient,
    settings: ScanSettings,
    capabilities: ScannerCapabilities
  ) async throws -> FlatbedScanResult {
    guard settings.source == .platen else {
      throw FlatbedScanError.requiresFlatbedSource
    }

    // If creation fails without a usable handle, cleanup cannot safely guess
    // which job belongs to this request. Do not retry creation automatically.
    let job = try await client.createJob(
      settings: settings,
      capabilities: capabilities
    )

    do {
      try Task.checkCancellation()

      guard let document = try await client.nextDocument(for: job) else {
        throw FlatbedScanError.noDocument
      }

      try Task.checkCancellation()

      let warning = await cleanup(client: client, job: job)
      return FlatbedScanResult(
        document: document,
        cleanupWarning: warning
      )
    } catch {
      let primaryError = error
      let warning = await cleanup(client: client, job: job)

      if let warning {
        throw FlatbedScanError.scanAndCleanupFailed(
          scan: String(reflecting: primaryError),
          cleanup: warning
        )
      }

      throw primaryError
    }
  }

  private static func cleanup(
    client: ScanJobClient,
    job: ScanJob
  ) async -> String? {
    // A detached cleanup task does not inherit the scan task's cancellation.
    // The production transport bounds DELETE to a 30-second resource timeout.
    await Task.detached(priority: .utility) { () -> String? in
      do {
        try await client.deleteJob(job)
        return nil
      } catch {
        return String(reflecting: error)
      }
    }.value
  }
}
