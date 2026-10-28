import AirScan
import Foundation
import SwiftUI

struct AirScanDiscoveredEndpoint: Identifiable, Hashable {
  let id: String
  let resourceRoot: URL

  var isEncrypted: Bool {
    resourceRoot.scheme == "https"
  }
}

struct AirScanDiscoveredDevice: Identifiable {
  let id: String
  let name: String
  let endpoints: [AirScanDiscoveredEndpoint]
}

@MainActor
final class AirScanDiscoveryModel:
  NSObject,
  ObservableObject,
  @preconcurrency NetServiceBrowserDelegate,
  @preconcurrency NetServiceDelegate
{
  @Published private(set) var devices: [AirScanDiscoveredDevice] = []
  @Published private(set) var isSearching = false
  @Published private(set) var errorMessage: String?

  private struct Record {
    let groupID: String
    let name: String
    let endpoint: AirScanDiscoveredEndpoint
  }

  private var browsers: [NetServiceBrowser] = []
  private var services: [String: NetService] = [:]
  private var records: [String: Record] = [:]
  private var events: [String] = []

  func start() {
    stop()

    services.removeAll()
    records.removeAll()
    devices = []
    errorMessage = nil
    isSearching = true
    record("Bonjour-Suche gestartet.")

    for type in ["_uscan._tcp.", "_uscans._tcp."] {
      let browser = NetServiceBrowser()
      browser.delegate = self
      browser.schedule(in: .main, forMode: .common)
      browsers.append(browser)
      browser.searchForServices(ofType: type, inDomain: "local.")
    }
  }

  func stop() {
    for browser in browsers {
      browser.delegate = nil
      browser.stop()
      browser.remove(from: .main, forMode: .common)
    }
    browsers.removeAll()

    for service in services.values {
      service.delegate = nil
      service.stopMonitoring()
      service.stop()
      service.remove(from: .main, forMode: .common)
    }
    services.removeAll()

    if isSearching {
      record("Bonjour-Suche beendet.")
    }
    isSearching = false
  }

  var debugReport: String {
    var lines = [
      "Bonjour-Diagnose",
      "Suche aktiv: \(isSearching ? "ja" : "nein")",
      "Auflösbare Verbindungen: \(records.count)",
      "Gruppierte Geräte: \(devices.count)"
    ]

    for device in devices {
      for endpoint in device.endpoints {
        let scheme = endpoint.resourceRoot.scheme ?? "?"
        let path = endpoint.resourceRoot.path
        lines.append("Verbindung: \(scheme), Ressourcenpfad: \(path)")
      }
    }

    lines.append(contentsOf: events)
    return lines.joined(separator: "\n")
  }

  func netServiceBrowser(
    _ browser: NetServiceBrowser,
    didFind service: NetService,
    moreComing: Bool
  ) {
    guard browsers.contains(where: { $0 === browser }) else { return }

    let key = serviceKey(service)
    guard services[key] == nil else { return }

    services[key] = service
    service.delegate = self
    service.schedule(in: .main, forMode: .common)
    service.resolve(withTimeout: 10)

    record("Dienst gefunden; Auflösung gestartet.")
  }

  func netServiceBrowser(
    _ browser: NetServiceBrowser,
    didRemove service: NetService,
    moreComing: Bool
  ) {
    guard browsers.contains(where: { $0 === browser }) else { return }

    let key = serviceKey(service)

    if let retained = services.removeValue(forKey: key) {
      retained.delegate = nil
      retained.stopMonitoring()
      retained.stop()
      retained.remove(from: .main, forMode: .common)
    }

    records.removeValue(forKey: key)
    publishDevices()
    record("Dienst entfernt.")
  }

  func netServiceBrowser(
    _ browser: NetServiceBrowser,
    didNotSearch errorDict: [String: NSNumber]
  ) {
    guard browsers.contains(where: { $0 === browser }) else { return }

    let code = errorDict["NSNetServicesErrorCode"]?.stringValue ?? "unbekannt"
    errorMessage =
      "Bonjour-Suche fehlgeschlagen (Code \(code)). "
      + "Lokalen Netzwerkzugriff und WLAN prüfen."

    record("Dienstsuche fehlgeschlagen; Code \(code).")

    browser.delegate = nil
    browser.stop()
    browser.remove(from: .main, forMode: .common)
    browsers.removeAll { $0 === browser }
    isSearching = !browsers.isEmpty
  }

  func netServiceDidResolveAddress(_ sender: NetService) {
    guard services[serviceKey(sender)] === sender else { return }

    sender.startMonitoring()
    updateRecord(sender)
  }

  func netService(
    _ sender: NetService,
    didUpdateTXTRecord data: Data
  ) {
    guard services[serviceKey(sender)] === sender else { return }
    updateRecord(sender)
  }

  func netService(
    _ sender: NetService,
    didNotResolve errorDict: [String: NSNumber]
  ) {
    guard services[serviceKey(sender)] === sender else { return }

    let code = errorDict["NSNetServicesErrorCode"]?.stringValue ?? "unbekannt"
    errorMessage =
      "Ein Scanner-Dienst konnte nicht aufgelöst werden (Code \(code))."
    record("Dienstauflösung fehlgeschlagen; Code \(code).")
  }

  private func updateRecord(_ service: NetService) {
    let key = serviceKey(service)

    guard let advertisedHost = service.hostName,
          (1...65535).contains(service.port),
          let data = service.txtRecordData() else {
      record("Dienst noch ohne vollständige Adresse oder TXT-Daten.")
      return
    }

    var txt: [String: String] = [:]

    for (name, value) in NetService.dictionary(fromTXTRecord: data) {
      if let string = String(data: value, encoding: .utf8) {
        txt[name.lowercased()] = string
      }
    }

    guard let rawPath = txt["rs"], !rawPath.isEmpty,
          let decodedPath = rawPath.removingPercentEncoding,
          !decodedPath.isEmpty,
          !decodedPath.contains("://"),
          !decodedPath.contains("?"),
          !decodedPath.contains("#"),
          !decodedPath.contains("\\") else {
      records.removeValue(forKey: key)
      publishDevices()
      record("Dienst ohne verwendbaren rs-Ressourcenpfad.")
      return
    }

    let segments = decodedPath.split(separator: "/")
    guard !segments.contains(where: { $0 == "." || $0 == ".." }) else {
      records.removeValue(forKey: key)
      publishDevices()
      record("Ressourcenpfad mit unzulässigen Pfadsegmenten verworfen.")
      return
    }

    var host = advertisedHost
    if host.hasSuffix(".") {
      host.removeLast()
    }

    let secure = service.type.lowercased().hasPrefix("_uscans.")
    var components = URLComponents()
    components.scheme = secure ? "https" : "http"
    components.host = host
    components.port = service.port
    components.path = "/" + segments.joined(separator: "/")

    guard let url = components.url,
          let validated = try? ScannerEndpoint(resourceRoot: url) else {
      record("Aufgelöste Scanner-Adresse nicht verwendbar.")
      return
    }

    let uuidText = txt["uuid"]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(of: "urn:uuid:", with: "")

    let groupID: String
    if let uuidText, let uuid = UUID(uuidString: uuidText) {
      groupID = "uuid:" + uuid.uuidString.lowercased()
    } else {
      // Without a UUID, only merge matching host/resource-path pairs.
      groupID = "host:" + host.lowercased() + validated.resourceRoot.path
    }

    let advertisedName = txt["ty"]?
      .trimmingCharacters(in: .whitespacesAndNewlines)

    let name: String
    if let advertisedName, !advertisedName.isEmpty {
      name = advertisedName
    } else {
      name = service.name
    }

    records[key] = Record(
      groupID: groupID,
      name: name,
      endpoint: AirScanDiscoveredEndpoint(
        id: key,
        resourceRoot: validated.resourceRoot
      )
    )

    publishDevices()
    record("Dienst aufgelöst: \(secure ? "HTTPS" : "HTTP").")
  }

  private func publishDevices() {
    let groups = Dictionary(grouping: records.values, by: \.groupID)

    devices = groups.map { id, group in
      let sorted = group.sorted {
        if $0.endpoint.isEncrypted != $1.endpoint.isEncrypted {
          return $0.endpoint.isEncrypted
        }
        return $0.endpoint.resourceRoot.absoluteString
          < $1.endpoint.resourceRoot.absoluteString
      }

      var seen = Set<String>()
      let endpoints = sorted.compactMap { record -> AirScanDiscoveredEndpoint? in
        let address = record.endpoint.resourceRoot.absoluteString
        guard seen.insert(address).inserted else { return nil }
        return record.endpoint
      }

      let name = group.map(\.name).sorted().first ?? "Scanner"
      return AirScanDiscoveredDevice(
        id: id,
        name: name,
        endpoints: endpoints
      )
    }
    .sorted {
      if $0.name == $1.name { return $0.id < $1.id }
      return $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
  }

  private func serviceKey(_ service: NetService) -> String {
    "\(service.domain)|\(service.type)|\(service.name)"
  }

  private func record(_ message: String) {
    events.append(message)
    if events.count > 100 {
      events.removeFirst(events.count - 100)
    }
  }
}
