import Foundation

/// The eSCL resource root, including its advertised path (for example /eSCL/).
/// This type does not discover a resource path or downgrade HTTPS to HTTP.
public struct ScannerEndpoint: Hashable, Sendable {
  public enum ValidationError: Error, Equatable, Sendable {
    case invalidURL
    case unsupportedScheme
    case missingHost
    case credentialsNotAllowed
    case queryOrFragmentNotAllowed
  }

  public let resourceRoot: URL

  public init(resourceRoot: URL) throws {
    guard var components = URLComponents(url: resourceRoot, resolvingAgainstBaseURL: false) else {
      throw ValidationError.invalidURL
    }
    guard let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
      throw ValidationError.unsupportedScheme
    }
    guard let host = components.host, !host.isEmpty else {
      throw ValidationError.missingHost
    }
    guard components.user == nil, components.password == nil else {
      throw ValidationError.credentialsNotAllowed
    }
    guard components.query == nil, components.fragment == nil else {
      throw ValidationError.queryOrFragmentNotAllowed
    }
    components.scheme = scheme
    if !components.percentEncodedPath.hasSuffix("/") {
      components.percentEncodedPath += "/"
    }
    guard let normalized = components.url else { throw ValidationError.invalidURL }
    self.resourceRoot = normalized
  }

  public var isEncrypted: Bool { resourceRoot.scheme == "https" }

  public var capabilitiesURL: URL {
    resourceRoot.appendingPathComponent("ScannerCapabilities")
  }

  public var statusURL: URL {
    resourceRoot.appendingPathComponent("ScannerStatus")
  }

  public var jobsURL: URL {
    resourceRoot.appendingPathComponent("ScanJobs")
  }
}
