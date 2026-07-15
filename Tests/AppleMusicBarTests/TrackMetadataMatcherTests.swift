import XCTest
@testable import AppleMusicBar

final class TrackMetadataMatcherTests: XCTestCase {
    func testCanonicalizesSimplifiedAndTraditionalChinese() {
        XCTAssertEqual(
            TrackMetadataMatcher.canonical("无尽的思念"),
            TrackMetadataMatcher.canonical("無盡的思念")
        )
        XCTAssertTrue(
            TrackMetadataMatcher.equivalent("编号89757", "編號 89757")
        )
    }

    func testCreatesTraditionalTitleFallback() {
        let variants = TrackMetadataMatcher.titleSearchVariants("无尽的思念")

        XCTAssertTrue(variants.contains("无尽的思念"))
        XCTAssertTrue(variants.contains("無盡的思念"))
        XCTAssertEqual(
            TrackMetadataMatcher.preferredTitleSearchTerm("无尽的思念"),
            "無盡的思念"
        )
    }

    func testDoesNotTreatEmptyMetadataAsEquivalent() {
        XCTAssertFalse(TrackMetadataMatcher.equivalent(nil, ""))
        XCTAssertFalse(TrackMetadataMatcher.equivalent("", ""))
    }

    func testCanonicalizationIgnoresSpacingAndPunctuation() {
        XCTAssertTrue(
            TrackMetadataMatcher.equivalent("編號 89757", "编号-89757")
        )
    }
}
