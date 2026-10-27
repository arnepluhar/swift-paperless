import Foundation
import XCTest
@testable import AirScan

final class ScanSettingsTests: XCTestCase {
  private func capabilities() throws -> ScannerCapabilities {
    let profiles = """
      <s:SettingProfiles>
        <s:SettingProfile>
          <s:ColorModes>
            <s:ColorMode>RGB24</s:ColorMode>
          </s:ColorModes>
          <s:DocumentFormats>
            <p:DocumentFormat>image/jpeg</p:DocumentFormat>
          </s:DocumentFormats>
          <s:SupportedResolutions>
            <s:DiscreteResolutions>
              <s:DiscreteResolution>
                <s:XResolution>150</s:XResolution>
                <s:YResolution>150</s:YResolution>
              </s:DiscreteResolution>
            </s:DiscreteResolutions>
          </s:SupportedResolutions>
        </s:SettingProfile>
        <s:SettingProfile>
          <s:ColorModes>
            <s:ColorMode>Grayscale8</s:ColorMode>
          </s:ColorModes>
          <s:DocumentFormats>
            <p:DocumentFormat>application/pdf</p:DocumentFormat>
          </s:DocumentFormats>
          <s:SupportedResolutions>
            <s:DiscreteResolutions>
              <s:DiscreteResolution>
                <s:XResolution>300</s:XResolution>
                <s:YResolution>300</s:YResolution>
              </s:DiscreteResolution>
            </s:DiscreteResolutions>
          </s:SupportedResolutions>
        </s:SettingProfile>
      </s:SettingProfiles>
      """

    let dimensions = """
      <s:MinWidth>32</s:MinWidth>
      <s:MaxWidth>2550</s:MaxWidth>
      <s:MinHeight>32</s:MinHeight>
      <s:MaxHeight>3508</s:MaxHeight>
      """

    let xml = """
      <s:ScannerCapabilities
        xmlns:s="http://schemas.hp.com/imaging/escl/2011/05/03"
        xmlns:p="http://www.pwg.org/schemas/2010/12/sm">
        <s:Platen>
          <s:PlatenInputCaps>
            \(dimensions)
            \(profiles)
          </s:PlatenInputCaps>
        </s:Platen>
        <s:Adf>
          <s:AdfSimplexInputCaps>
            \(dimensions)
            \(profiles)
          </s:AdfSimplexInputCaps>
          <s:AdfDuplexInputCaps>
            \(dimensions)
            \(profiles)
          </s:AdfDuplexInputCaps>
        </s:Adf>
      </s:ScannerCapabilities>
      """

    return try CapabilitiesParser.parse(Data(xml.utf8))
  }

  private func settings(
    source: ScannerCapabilities.Source = .platen,
    resolution: Int = 150,
    width: Int = 2480
  ) -> ScanSettings {
    ScanSettings(
      source: source,
      colorMode: .color,
      documentFormat: .jpeg,
      resolution: resolution,
      width: width,
      height: 3508
    )
  }

  func testBuildsFlatbedSettingsWithoutDuplexElement() throws {
    let data = try settings().xml(validating: capabilities())
    let xml = try XCTUnwrap(String(data: data, encoding: .utf8))

    XCTAssertTrue(xml.contains("<pwg:InputSource>Platen</pwg:InputSource>"))
    XCTAssertTrue(xml.contains("<pwg:Width>2480</pwg:Width>"))
    XCTAssertTrue(xml.contains("<pwg:Height>3508</pwg:Height>"))
    XCTAssertTrue(xml.contains("<scan:XResolution>150</scan:XResolution>"))
    XCTAssertTrue(xml.contains("<scan:ColorMode>RGB24</scan:ColorMode>"))
    XCTAssertTrue(xml.contains("<pwg:DocumentFormat>image/jpeg</pwg:DocumentFormat>"))
    XCTAssertFalse(xml.contains("<scan:Duplex>"))
  }

  func testBuildsSimplexFeederSettings() throws {
    let data = try settings(source: .feederSimplex)
      .xml(validating: capabilities())
    let xml = try XCTUnwrap(String(data: data, encoding: .utf8))

    XCTAssertTrue(xml.contains("<pwg:InputSource>Feeder</pwg:InputSource>"))
    XCTAssertTrue(xml.contains("<scan:Duplex>false</scan:Duplex>"))
  }

  func testBuildsDuplexFeederSettings() throws {
    let data = try settings(source: .feederDuplex)
      .xml(validating: capabilities())
    let xml = try XCTUnwrap(String(data: data, encoding: .utf8))

    XCTAssertTrue(xml.contains("<pwg:InputSource>Feeder</pwg:InputSource>"))
    XCTAssertTrue(xml.contains("<scan:Duplex>true</scan:Duplex>"))
  }

  func testRejectsCrossProfileCombination() throws {
    let caps = try capabilities()

    // Color and 300 dpi are advertised, but not in the same profile.
    XCTAssertThrowsError(
      try settings(resolution: 300).xml(validating: caps)
    ) { error in
      XCTAssertEqual(
        error as? ScanSettingsError,
        .unsupportedProfileCombination
      )
    }
  }

  func testRejectsInvalidDimensions() throws {
    let caps = try capabilities()

    for width in [-1, 0, 31, 2551] {
      XCTAssertThrowsError(
        try settings(width: width).xml(validating: caps)
      ) { error in
        XCTAssertEqual(error as? ScanSettingsError, .invalidDimensions)
      }
    }
  }

  func testRejectsUnavailableSource() throws {
    let empty = Data("""
      <s:ScannerCapabilities
        xmlns:s="http://schemas.hp.com/imaging/escl/2011/05/03"/>
      """.utf8)
    let caps = try CapabilitiesParser.parse(empty)

    XCTAssertThrowsError(
      try settings().xml(validating: caps)
    ) { error in
      XCTAssertEqual(error as? ScanSettingsError, .unsupportedSource)
    }
  }
}
