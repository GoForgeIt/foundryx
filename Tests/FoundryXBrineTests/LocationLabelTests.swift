import XCTest
@testable import FoundryXKit

/// The conversation place label is "City, State, Country" (the where-it-happened the
/// card shows + the door threads into the Lore ingest envelope as location.label).
/// These lock the pure formatter's graceful-omission behavior; the live CLGeocoder
/// reverse-geocode that feeds it needs a device and isn't unit-tested.
final class LocationLabelTests: XCTestCase {

    func testFullCityStateCountry() {
        XCTAssertEqual(
            foundryxPlaceLabel(city: "San Francisco", state: "California", country: "United States"),
            "San Francisco, California, United States")
    }

    func testOmitsMissingComponents() {
        XCTAssertEqual(foundryxPlaceLabel(city: "Berlin", state: nil, country: "Germany"),
                       "Berlin, Germany")
        XCTAssertEqual(foundryxPlaceLabel(city: nil, state: "Texas", country: "United States"),
                       "Texas, United States")
        XCTAssertEqual(foundryxPlaceLabel(city: "Denver", state: "Colorado", country: nil),
                       "Denver, Colorado")
    }

    func testEmptyAndWhitespaceComponentsAreDropped() {
        XCTAssertEqual(foundryxPlaceLabel(city: "  ", state: "", country: "Canada"), "Canada")
        XCTAssertNil(foundryxPlaceLabel(city: nil, state: nil, country: nil),
                     "no components → nil → card shows time only (honest degradation)")
        XCTAssertNil(foundryxPlaceLabel(city: "  ", state: "", country: nil))
    }

    func testThreadsThroughFinalizeBodyAsLocationLabel() throws {
        let meta = ConversationMeta(
            startedAt: 1000, endedAt: 1060,
            location: ConversationLocation(lat: 37.77, long: -122.41,
                                           label: foundryxPlaceLabel(city: "San Francisco",
                                                                     state: "California",
                                                                     country: "United States")))
        let data = try JSONEncoder().encode(FinalizeBody(meta: meta))
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"label\":\"San Francisco, California, United States\""),
                      "the city/state/country label is in the finalize body the door forwards to Lore")
    }
}
