import Foundation
import XCTest
@testable import AirScan

final class CapabilitiesParserTests: XCTestCase {
  private func document(_ body: String, prefix: String = "s") -> Data {
    Data(("<\(prefix):ScannerCapabilities xmlns:\(prefix)=\"http://schemas.hp.com/imaging/escl/2011/05/03\" xmlns:p=\"http://www.pwg.org/schemas/2010/12/sm\">" + body + "</\(prefix):ScannerCapabilities>").utf8)
  }

  private let profile = """
    <s:SettingProfiles><s:SettingProfile>
      <s:ColorModes><s:ColorMode>RGB24</s:ColorMode></s:ColorModes>
      <s:DocumentFormats><p:DocumentFormat>image/jpeg</p:DocumentFormat></s:DocumentFormats>
      <s:SupportedResolutions><s:DiscreteResolutions><s:DiscreteResolution>
        <s:XResolution>300</s:XResolution><s:YResolution>600</s:YResolution>
      </s:DiscreteResolution></s:DiscreteResolutions></s:SupportedResolutions>
    </s:SettingProfile></s:SettingProfiles>
    """

    func testSeparatesAllSourcesAndProfiles() throws {
      // Build two profiles inside one SettingProfiles container.
      let grayscaleProfile = profile
        .replacingOccurrences(of: "RGB24", with: "Grayscale8")

      let duplexProfiles = profile
        .replacingOccurrences(of: "</s:SettingProfiles>", with: "")
        + grayscaleProfile
          .replacingOccurrences(of: "<s:SettingProfiles>", with: "")

      let xml = document("""
        <p:MakeAndModel>Test scanner</p:MakeAndModel>
        <s:Platen>
          <s:PlatenInputCaps>
            <s:MaxWidth>2550</s:MaxWidth>
            \(profile)
          </s:PlatenInputCaps>
        </s:Platen>
        <s:Adf>
          <s:AdfSimplexInputCaps>
            \(profile)
          </s:AdfSimplexInputCaps>
          <s:AdfDuplexInputCaps>
            \(duplexProfiles)
          </s:AdfDuplexInputCaps>
        </s:Adf>
        """)

      let caps = try CapabilitiesParser.parse(xml)

      XCTAssertEqual(caps.makeAndModel, "Test scanner")
      XCTAssertEqual(
        caps.inputs.map(\.source),
        [.platen, .feederSimplex, .feederDuplex]
      )

      let platen = try XCTUnwrap(
        caps.inputs.first { $0.source == .platen }
      )
      XCTAssertEqual(platen.maxWidth, 2550)

      let platenProfile = try XCTUnwrap(platen.profiles.first)
      XCTAssertEqual(
        platenProfile.resolutions,
        [.init(x: 300, y: 600)]
      )
      XCTAssertEqual(platenProfile.documentFormats, ["image/jpeg"])

      let duplex = try XCTUnwrap(
        caps.inputs.first { $0.source == .feederDuplex }
      )
      XCTAssertEqual(duplex.profiles.count, 2)
      XCTAssertEqual(
        duplex.profiles.map(\.colorModes),
        [["RGB24"], ["Grayscale8"]]
      )
    }

  
  func testPrefixesAreNotHardCoded() throws {
    let body = "<s:Platen><s:PlatenInputCaps>\(profile)</s:PlatenInputCaps></s:Platen>"
    let caps = try CapabilitiesParser.parse(document(body.replacingOccurrences(of: "s:", with: "other:"), prefix: "other"))
    XCTAssertEqual(caps.inputs.first?.profiles.first?.colorModes, ["RGB24"])
  }

  func testIgnoresForeignNamespace() throws {
    let caps = try CapabilitiesParser.parse(document("<foreign:Platen xmlns:foreign=\"urn:foreign\"><foreign:PlatenInputCaps/></foreign:Platen>"))
    XCTAssertTrue(caps.inputs.isEmpty)
  }

  func testParsesAdjustmentsWithoutInventingDefaults() throws {
    let caps = try CapabilitiesParser.parse(document("""
      <s:ContrastSupport><s:Min>-100</s:Min><s:Max>100</s:Max><s:Normal>0</s:Normal><s:Step>1</s:Step></s:ContrastSupport>
      <s:GammaSupport><s:Min>100</s:Min><s:Max>300</s:Max></s:GammaSupport>
      """))
    XCTAssertEqual(caps.adjustments[.contrast]?.normal, 0)
    XCTAssertNil(caps.adjustments[.gamma]?.normal)
    XCTAssertNil(caps.adjustments[.brightness])
  }

  func testRejectsMalformedXMLAndWrongRoot() {
    XCTAssertThrowsError(try CapabilitiesParser.parse(Data("<broken>".utf8)))
    XCTAssertThrowsError(try CapabilitiesParser.parse(Data("<ScannerCapabilities/>".utf8)))
  }

  func testRejectsInvalidRangesAndNumbers() {
    for body in [
      "<s:GammaSupport><s:Min>5</s:Min><s:Max>1</s:Max></s:GammaSupport>",
      "<s:Platen><s:PlatenInputCaps><s:MaxWidth>oops</s:MaxWidth></s:PlatenInputCaps></s:Platen>",
    ] {
      XCTAssertThrowsError(try CapabilitiesParser.parse(document(body)))
    }
  }

  func testRejectsOversizedDocument() {
    XCTAssertThrowsError(try CapabilitiesParser.parse(Data(repeating: 32, count: 2_000_001)))
  }
}
