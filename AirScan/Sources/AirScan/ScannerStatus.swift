import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public enum ScannerStatusError: Error, Equatable, Sendable {
  case malformedXML
  case unexpectedRoot
  case invalidValue(String)
  case httpStatus(Int)
  case paperJam
  case feederEmpty
  case scannerNotIdle(String)
  case feederNotReady(String)
  case completionNotConfirmed
}

public struct ScannerStatus: Sendable, Equatable {
  public struct Job: Sendable, Equatable {
    public let uri: String
    public let state: String?
    public let imagesCompleted: Int?
    public let reasons: [String]
  }

  public let state: String?
  public let adfState: String?
  public let jobs: [Job]

  /// Conservative first implementation: unknown states do not start a scan.
  public func requireFeederReady() throws {
    if adfState == "ScannerAdfJam" {
      throw ScannerStatusError.paperJam
    }

    if adfState == "ScannerAdfEmpty" {
      throw ScannerStatusError.feederEmpty
    }

    guard state == "Idle" else {
      throw ScannerStatusError.scannerNotIdle(state ?? "not advertised")
    }

    guard adfState == "ScannerAdfLoaded" else {
      throw ScannerStatusError.feederNotReady(adfState ?? "not advertised")
    }
  }

  public func requireCompleted(
    jobURL: URL,
    resourceRoot: URL,
    receivedPages: Int
  ) throws {
    guard let expected = Self.identity(jobURL) else {
      throw ScannerStatusError.completionNotConfirmed
    }

    let matching = jobs.filter { job in
      guard let resolved = URL(
        string: job.uri,
        relativeTo: resourceRoot
      )?.absoluteURL else {
        return false
      }
      return Self.identity(resolved) == expected
    }

    guard matching.count == 1,
          let job = matching.first,
          job.state == "Completed",
          job.imagesCompleted == receivedPages else {
      throw ScannerStatusError.completionNotConfirmed
    }

    // Missing reasons remain permissible when Completed and count agree.
    // Advertised reasons must include explicit success for this first workflow.
    if !job.reasons.isEmpty,
       !job.reasons.contains("JobCompletedSuccessfully") {
      throw ScannerStatusError.completionNotConfirmed
    }
  }

  private static func identity(_ url: URL) -> String? {
    guard let parts = URLComponents(
      url: url,
      resolvingAgainstBaseURL: false
    ),
      let scheme = parts.scheme?.lowercased(),
      ["http", "https"].contains(scheme),
      let host = parts.host?.lowercased(),
      parts.user == nil,
      parts.password == nil,
      parts.query == nil,
      parts.fragment == nil else {
      return nil
    }

    let port = parts.port ?? (scheme == "https" ? 443 : 80)
    return "\(scheme)://\(host):\(port)\(parts.percentEncodedPath)"
  }
}

public enum ScannerStatusParser {
  public static func parse(_ data: Data) throws -> ScannerStatus {
    guard data.count <= CapabilitiesClient.maximumResponseBytes else {
      throw CapabilitiesClientError.responseTooLarge
    }

    let builder = CapabilityTreeBuilder()
    let parser = XMLParser(data: data)
    parser.shouldProcessNamespaces = true
    parser.shouldResolveExternalEntities = false
    parser.delegate = builder

    let success = parser.parse()

    if let error = builder.failure {
      throw error
    }

    guard success, let root = builder.root else {
      throw ScannerStatusError.malformedXML
    }

    guard root.matches("ScannerStatus", namespace: scanNamespace) else {
      throw ScannerStatusError.unexpectedRoot
    }

    var jobs: [ScannerStatus.Job] = []

    for node in root.child("Jobs")?.children ?? [] {
      guard node.matches("JobInfo", namespace: scanNamespace) else {
        continue
      }

      guard let uri = node.child("JobUri", namespace: pwgNamespace)?.value,
            !uri.isEmpty else {
        throw ScannerStatusError.invalidValue("JobUri")
      }

      var imagesCompleted: Int?
      if let value = node.child(
        "ImagesCompleted",
        namespace: pwgNamespace
      )?.value {
        guard let count = Int(value), count >= 0 else {
          throw ScannerStatusError.invalidValue("ImagesCompleted")
        }
        imagesCompleted = count
      }

      jobs.append(.init(
        uri: uri,
        state: node.child("JobState", namespace: pwgNamespace)?.value,
        imagesCompleted: imagesCompleted,
        reasons: node.child(
          "JobStateReasons",
          namespace: pwgNamespace
        )?.values("JobStateReason", namespace: pwgNamespace) ?? []
      ))
    }

    return ScannerStatus(
      state: root.child("State", namespace: pwgNamespace)?.value,
      adfState: root.child("AdfState")?.value,
      jobs: jobs
    )
  }
}

public struct ScannerStatusClient: Sendable {
  private let transport: any ScannerHTTPTransport

  public init(
    transport: any ScannerHTTPTransport = URLSessionScannerTransport()
  ) {
    self.transport = transport
  }

  public func fetch(from endpoint: ScannerEndpoint) async throws -> ScannerStatus {
    try Task.checkCancellation()

    let response = try await transport.get(endpoint.statusURL)

    try Task.checkCancellation()

    guard response.statusCode == 200 else {
      throw ScannerStatusError.httpStatus(response.statusCode)
    }

    return try ScannerStatusParser.parse(response.body)
  }
}
