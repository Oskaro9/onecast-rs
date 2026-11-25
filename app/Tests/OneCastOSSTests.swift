import CoreMedia
import Foundation
import OneCastCore
import XCTest
@testable import OneCastOSS

final class OneCastOSSTests: XCTestCase {
    func testCoreInitializesAndBuildsOAuthURL() throws {
        let core = try OneCastCore()
        let url = core.oauthAuthorizeUrl()
        XCTAssertTrue(url.contains("login.live.com/oauth20_authorize.srf"))
        XCTAssertTrue(url.contains("MBI_SSL"))
    }

    func testSplitAnnexBNalUnits() {
        let stream = Data([
            0x00, 0x00, 0x00, 0x01, 0x67, 0x42, 0x00, 0x1E,
            0x00, 0x00, 0x01, 0x68, 0xCE, 0x3C, 0x80,
            0x00, 0x00, 0x00, 0x01, 0x65, 0x88, 0x84
        ])
        let nals = H264SampleBufferBuilder.splitAnnexBNalUnits(stream)
        XCTAssertEqual(nals.count, 3)
        XCTAssertEqual(nals[0].first, 0x67)
        XCTAssertEqual(nals[1].first, 0x68)
        XCTAssertEqual(nals[2].first, 0x65)
    }

    func testSampleBufferCreationFromSyntheticH264() {
        // Valid H.264 Baseline Profile 320x240 SPS + PPS + IDR slice
        let annexB = Data([
            0x00, 0x00, 0x00, 0x01,
            0x67, 0x42, 0xC0, 0x0D, 0xD9, 0x01, 0x41, 0xFA, 0x10, 0x00, 0x00, 0x03, 0x00, 0x10, 0x00, 0x00, 0x03, 0x03, 0xC0, 0xF1, 0x42, 0x99, 0x60,
            0x00, 0x00, 0x00, 0x01,
            0x68, 0xCE, 0x3C, 0x80,
            0x00, 0x00, 0x00, 0x01,
            0x65, 0x88, 0x84, 0x21, 0xA0
        ])
        let builder = H264SampleBufferBuilder()
        let sample = builder.makeSampleBuffer(fromAnnexB: annexB, ptsUs: 33_333)
        XCTAssertNotNil(sample)
        if let sample {
            XCTAssertEqual(CMSampleBufferGetNumSamples(sample), 1)
        }
    }
}
