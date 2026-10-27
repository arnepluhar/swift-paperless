import Foundation
import XCTest
@testable import AirScan

final class AdditionalCapabilitiesTests: XCTestCase {
  private func document(_ body: String) -> Data {
    Data("""
      <s:ScannerCapabilities
        xmlns:s="http://schemas.hp.com/imaging/escl/2011/05/03">
        \(body)
      </s:ScannerCapabilities>
      """.utf8)
  }

  func testPreservesSeparateBlankPageCapabilities() throws {
    let capabilities = try CapabilitiesParser.parse(document("""
      <s:BlankPageDetection>false</s:BlankPageDetection>
      <s:BlankPageDetectionAndRemoval>true</s:BlankPageDetectionAndRemoval>
      """))

    XCTAssertEqual(capabilities.blankPageDetection, false)
    XCTAssertEqual(capabilities.blankPageDetectionAndRemoval, true)
  }

  func testMissingBlankPageCapabilitiesRemainUnknown() throws {
    let capabilities = try CapabilitiesParser.parse(document(""))

    XCTAssertNil(capabilities.blankPageDetection)
    XCTAssertNil(capabilities.blankPageDetectionAndRemoval)
  }

  func testRejectsInvalidBoolean() {
    XCTAssertThrowsError(
      try CapabilitiesParser.parse(document("""
        <s:BlankPageDetection>maybe</s:BlankPageDetection>
        """))
    ) { error in
      XCTAssertEqual(
        error as? CapabilitiesParsingError,
        .invalidValue("BlankPageDetection")
      )
    }
  }

  func testPreservesContentTypesAndIntentsAtTheirOwnScope() throws {
    let capabilities = try CapabilitiesParser.parse(document("""
      <s:Platen>
        <s:PlatenInputCaps>
          <s:SettingProfiles>
            <s:SettingProfile>
              <s:ColorModes>
                <s:ColorMode>RGB24</s:ColorMode>
              </s:ColorModes>
              <s:ContentTypes>
                <s:ContentType>Photo</s:ContentType>
                <s:ContentType>Text</s:ContentType>
                <s:ContentType>TextAndPhoto</s:ContentType>
              </s:ContentTypes>
            </s:SettingProfile>
          </s:SettingProfiles>
          <s:SupportedIntents>
            <s:Intent>Document</s:Intent>
            <s:Intent>Photo</s:Intent>
            <s:Intent>TextAndGraphic</s:Intent>
            <s:Intent>Preview</s:Intent>
          </s:SupportedIntents>
        </s:PlatenInputCaps>
      </s:Platen>
      """))

    let input = try XCTUnwrap(capabilities.inputs.first)
    let profile = try XCTUnwrap(input.profiles.first)

    XCTAssertEqual(
      profile.contentTypes,
      ["Photo", "Text", "TextAndPhoto"]
    )
    XCTAssertEqual(
      input.supportedIntents,
      ["Document", "Photo", "TextAndGraphic", "Preview"]
    )
  }
}
