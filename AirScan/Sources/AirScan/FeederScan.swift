import Foundation

public enum FeederScanError: Error, Equatable, Sendable {
  case invalidConfiguration
  case unexpectedPageCount(expected: Int, received: Int)
  case scanAndCleanupFailed(scan: String, cleanup: String)
}

public struct FeederScanResult: Sendable {
  public let pageCount: Int
  public let cleanupWarning: String?
}

public enum FeederScan {
  public static func run(
    client: ScanJobClient,
    settings: ScanSettings,
    capabilities: ScannerCapabilities,
    expectedPages: Int,
    verifyCompletion: @Sendable (ScanJob, Int) async throws -> Void = { _, _ in },
    receivePage: @Sendable (ScannedDocument, Int) async throws -> Void
  ) async throws -> FeederScanResult {
    guard settings.source != .platen,
          settings.documentFormat == .jpeg,
          (1...100).contains(expectedPages) else {
      throw FeederScanError.invalidConfiguration
    }

    let job = try await client.createJob(
      settings: settings,
      capabilities: capabilities
    )

    do {
      var received = 0

      while true {
        try Task.checkCancellation()

        guard let document = try await client.nextDocument(for: job) else {
          break
        }

        received += 1

        // Persist each page before proceeding to another network request.
        try await receivePage(document, received)

        // Preserve one unexpected extra page, then stop and clean up.
        guard received <= expectedPages else {
          throw FeederScanError.unexpectedPageCount(
            expected: expectedPages,
            received: received
          )
        }
      }

      guard received == expectedPages else {
        throw FeederScanError.unexpectedPageCount(
          expected: expectedPages,
          received: received
        )
      }

      try await verifyCompletion(job, received)

      let warning = await cleanup(client: client, job: job)
      return FeederScanResult(
        pageCount: received,
        cleanupWarning: warning
      )
    } catch {
      let primaryError = error
      let warning = await cleanup(client: client, job: job)

      if let warning {
        throw FeederScanError.scanAndCleanupFailed(
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
