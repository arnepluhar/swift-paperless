import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public enum CapabilitiesParsingError: Error, Equatable {
  case malformedXML
  case unexpectedRoot
  case resourceLimit
  case unsupportedProfileReference
  case unsupportedResolutionRange
  case invalidValue(String)
}

public enum CapabilitiesParser {
  public static func parse(_ data: Data) throws -> ScannerCapabilities {
    guard data.count <= 2_000_000 else { throw CapabilitiesParsingError.resourceLimit }
    let delegate = CapabilityTreeBuilder()
    let parser = XMLParser(data: data)
    parser.shouldProcessNamespaces = true
    parser.shouldResolveExternalEntities = false
    parser.delegate = delegate
    let success = parser.parse()
    if let error = delegate.failure { throw error }
    guard success, let root = delegate.root else {
      throw CapabilitiesParsingError.malformedXML
    }
    guard root.matches("ScannerCapabilities", namespace: scanNamespace) else {
      throw CapabilitiesParsingError.unexpectedRoot
    }
    var inputs: [ScannerCapabilities.Input] = []
    let containers: [(ScannerCapabilities.Source, CapabilityNode?)] = [
      (.platen, root.child("Platen")?.child("PlatenInputCaps")),
      (.feederSimplex, root.child("Adf")?.child("AdfSimplexInputCaps")),
      (.feederDuplex, root.child("Adf")?.child("AdfDuplexInputCaps")),
    ]
    for (source, node) in containers {
      guard let node else { continue }
      let profileNodes = node.child("SettingProfiles")?.children.filter {
        $0.matches("SettingProfile", namespace: scanNamespace)
      } ?? []
      var profiles: [ScannerCapabilities.Profile] = []
      for profile in profileNodes {
        // References need explicit resolution; never present them as unrestricted profiles.
        if profile.attributes.keys.contains(where: { $0.lowercased().contains("ref") }) {
          throw CapabilitiesParsingError.unsupportedProfileReference
        }
        let supported = profile.child("SupportedResolutions")
        if supported?.child("ResolutionRange") != nil {
          throw CapabilitiesParsingError.unsupportedResolutionRange
        }
        var resolutions: [ScannerCapabilities.Resolution] = []
        for r in supported?.child("DiscreteResolutions")?.children ?? [] {
          guard r.matches("DiscreteResolution", namespace: scanNamespace) else { continue }
          guard let x = try r.integer("XResolution"),
                let y = try r.integer("YResolution"), x > 0, y > 0 else {
            throw CapabilitiesParsingError.invalidValue("DiscreteResolution")
          }
          resolutions.append(.init(x: x, y: y))
        }
        let formats = (profile.child("DocumentFormats")?.values("DocumentFormat", namespace: pwgNamespace) ?? [])
          + (profile.child("DocumentFormats")?.values("DocumentFormatExt") ?? [])
        profiles.append(.init(
          colorModes: profile.child("ColorModes")?.values("ColorMode") ?? [],
          contentTypes: profile.child("ContentTypes")?.values("ContentType") ?? [],
          documentFormats: Array(Set(formats)).sorted(),
          resolutions: resolutions
        ))
      }
      inputs.append(.init(source: source,
        minWidth: try node.integer("MinWidth"), maxWidth: try node.integer("MaxWidth"),
        minHeight: try node.integer("MinHeight"), maxHeight: try node.integer("MaxHeight"),
        profiles: profiles,
        supportedIntents: node.child("SupportedIntents")?.values("Intent") ?? []))
    }
    var adjustments: [ScannerCapabilities.Adjustment: ScannerCapabilities.AdjustmentRange] = [:]
    for adjustment in ScannerCapabilities.Adjustment.allCases {
      guard let node = root.child(adjustment.rawValue) else { continue }
      guard let minimum = try node.integer("Min"), let maximum = try node.integer("Max"),
            minimum <= maximum else {
        throw CapabilitiesParsingError.invalidValue(adjustment.rawValue)
      }
      let normal = try node.integer("Normal")
      let step = try node.integer("Step")
      if let normal, !(minimum...maximum).contains(normal) {
        throw CapabilitiesParsingError.invalidValue(adjustment.rawValue)
      }
      if let step, step <= 0 { throw CapabilitiesParsingError.invalidValue(adjustment.rawValue) }
      adjustments[adjustment] = .init(minimum: minimum, maximum: maximum, normal: normal, step: step)
    }
    return .init(
      makeAndModel: root.child("MakeAndModel", namespace: pwgNamespace)?.value,
      blankPageDetection: try root.boolean("BlankPageDetection"),
      blankPageDetectionAndRemoval: try root.boolean("BlankPageDetectionAndRemoval"),
      inputs: inputs,
      adjustments: adjustments
    )
  }
}

let scanNamespace = "http://schemas.hp.com/imaging/escl/2011/05/03"
let pwgNamespace = "http://www.pwg.org/schemas/2010/12/sm"

final class CapabilityNode {
  let name: String
  let namespace: String
  let attributes: [String: String]
  var text = ""
  var children: [CapabilityNode] = []
  var value: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

  init(name: String, namespace: String, attributes: [String: String]) {
    self.name = name
    self.namespace = namespace
    self.attributes = attributes
  }

  func matches(_ name: String, namespace: String) -> Bool {
    self.name == name && self.namespace == namespace
  }

  func child(_ name: String, namespace: String = scanNamespace) -> CapabilityNode? {
    children.first { $0.matches(name, namespace: namespace) }
  }

  func values(_ name: String, namespace: String = scanNamespace) -> [String] {
    children.filter { $0.matches(name, namespace: namespace) }.map(\.value)
  }

  func boolean(_ name: String) throws -> Bool? {
    guard let node = child(name) else { return nil }
    switch node.value {
    case "true", "1": return true
    case "false", "0": return false
    default: throw CapabilitiesParsingError.invalidValue(name)
    }
  }

  func integer(_ name: String) throws -> Int? {
    guard let node = child(name) else { return nil }
    guard let number = Int(node.value) else { throw CapabilitiesParsingError.invalidValue(name) }
    return number
  }
}

final class CapabilityTreeBuilder: NSObject, XMLParserDelegate {
  var root: CapabilityNode?
  var stack: [CapabilityNode] = []
  var failure: CapabilitiesParsingError?
  var count = 0

  func parser(_ parser: XMLParser, didStartElement elementName: String,
              namespaceURI: String?, qualifiedName qName: String?,
              attributes attributeDict: [String: String]) {
    count += 1
    guard stack.count < 64, count <= 20_000 else {
      failure = .resourceLimit
      parser.abortParsing()
      return
    }
    let node = CapabilityNode(name: elementName, namespace: namespaceURI ?? "", attributes: attributeDict)
    if let parent = stack.last { parent.children.append(node) } else { root = node }
    stack.append(node)
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    stack.last?.text += string
  }

  func parser(_ parser: XMLParser, didEndElement elementName: String,
              namespaceURI: String?, qualifiedName qName: String?) {
    if !stack.isEmpty { stack.removeLast() }
  }
}
