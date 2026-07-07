import XCTest
import FoundryXKit

/// The on-device brain readiness banner state (track 20260705T1100, model-download
/// UX). Pure state → copy mapping so the first-recording download is never a silent
/// hang.
@MainActor
final class LocalBrainStatusTests: XCTestCase {

    func testIdleAndReadyShowNoBanner() {
        let s = LocalBrainStatus()
        XCTAssertNil(s.bannerText)
        XCTAssertFalse(s.isPreparing)
        s.setReady()
        XCTAssertNil(s.bannerText)
        XCTAssertFalse(s.isPreparing)
    }

    func testDownloadingShowsPercentAndIsPreparing() {
        let s = LocalBrainStatus()
        s.setDownloading(0.42)
        XCTAssertEqual(s.bannerText, "Setting up your private on-device brain… 42%")
        XCTAssertTrue(s.isPreparing)
    }

    func testDownloadFractionIsClamped() {
        let s = LocalBrainStatus()
        s.setDownloading(1.7)
        XCTAssertEqual(s.bannerText, "Setting up your private on-device brain… 100%")
        s.setDownloading(-0.5)
        XCTAssertEqual(s.bannerText, "Setting up your private on-device brain… 0%")
    }

    func testLoadingHasBannerWithoutPercent() {
        let s = LocalBrainStatus()
        s.setLoading()
        XCTAssertEqual(s.bannerText, "Setting up your private on-device brain…")
        XCTAssertTrue(s.isPreparing)
    }

    func testFailureSurfacesTheReasonAndStopsPreparing() {
        let s = LocalBrainStatus()
        s.setFailed("no network")
        XCTAssertEqual(s.bannerText, "On-device brain setup failed: no network")
        XCTAssertFalse(s.isPreparing)
    }
}
