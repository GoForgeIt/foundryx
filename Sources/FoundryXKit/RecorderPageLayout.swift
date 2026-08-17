// RecorderPageLayout.swift — WHAT ORDER THE RECORDER PAGE'S BANDS COME IN, DECIDED IN THE KIT.
//
// THE DEFECT THIS CLOSES, in Nick's own words about his own recorder page: *"there is lots of
// scrolling to get to any of the important controls or information."* His unit was holding
// nineteen recordings. Every control that acts on those recordings — bring one over, sync them
// over Wi-Fi, start the recorder over, arm the automatic clear — was drawn BELOW all nineteen
// rows, because they were nested inside the shelf that lists them. The shelf is the only band on
// this page with no ceiling: it is as long as the recorder is full. A control placed after an
// unbounded list is a control whose distance from the top is a property of somebody else's
// hardware, and on a full recorder that is indistinguishable from a control that was never
// built.
//
// WHY THE ORDER IS A VALUE AND NOT A SEQUENCE OF LINES IN A SwiftUI BODY. `swift test` cannot
// compile `App/`, so an order written as eleven statements inside a `VStack` is invisible to
// every test in this repository — which is exactly how the controls ended up under the list and
// stayed there through a shipped build. Here it is an array Brine can read, and the view's only
// job is to walk it.
//
// WHAT IS DELIBERATELY NOT DECIDED HERE: what any band CONTAINS, or whether it draws at all.
// A band whose content is absent draws nothing and costs nothing; the order is the same either
// way, which is the property that makes it checkable without a radio.

import Foundation

/// One band of the recorder page, in the vocabulary the page is actually laid out in.
///
/// `recordingIndicator` is a band rather than a decoration on purpose. It carries the sentence
/// that says the light on the device is the only recording indicator there is, and it occupies
/// the band where a live device would carry record / pause / stop. The empty space is not
/// blanked; it is occupied by the true fact — and a band it cannot be reordered out of is how
/// that stays true.
public enum RecorderPageBand: String, CaseIterable, Sendable, Hashable {
    /// The class eyebrow and the status line.
    case header
    /// The design's single most important sentence, in the band a live device uses for
    /// record / pause / stop.
    case recordingIndicator
    /// What the recorder said, and how old it is.
    case readings
    /// What the device declared it can do.
    case capabilities
    /// Whether this device is used for capture at all.
    case captureToggle
    /// The page's primary actions — connect and check, forget, the key.
    case actions
    /// The shelf's title, and what a check is doing or could not do.
    case shelfHeadline
    /// Everything a person can DO with what the recorder is holding: bring one over, sync
    /// fast, and what the recorder answered when it was asked to remove something.
    case shelfControls
    /// The cost of starting the recorder over, and the button that does it.
    case resetGate
    /// The standing choice about whether this recorder clears itself.
    case autoClear
    /// THE LIST. As long as the recorder is full, and therefore last.
    case shelfRows
}

public enum RecorderPageLayout {

    /// THE ORDER A PERSON MEETS THE BANDS IN. The list is last; everything actionable is above
    /// it. Nothing else about this array is asserted — the bands between the header and the
    /// list may be resequenced by anybody redesigning the page without touching a test.
    public static let order: [RecorderPageBand] = [
        .header,
        .recordingIndicator,
        .readings,
        .capabilities,
        .captureToggle,
        .actions,
        .shelfHeadline,
        .shelfControls,
        .resetGate,
        .autoClear,
        .shelfRows,
    ]

    /// THE BANDS A PERSON CAN ACT ON — every one of them contains at least one control that
    /// changes something. This is the set the ordering rule is about; a band that only states
    /// a fact may sit anywhere.
    public static let controls: [RecorderPageBand] = [
        .captureToggle, .actions, .shelfControls, .resetGate, .autoClear,
    ]

    /// THE ONE BAND WITH NO CEILING. Every other band on this page is a fixed number of lines;
    /// this one is a row per recording the recorder is holding, and Nick's was holding
    /// nineteen.
    public static let unboundedList: RecorderPageBand = .shelfRows

    /// Where a band sits, or nil when the layout does not draw it at all.
    public static func position(of band: RecorderPageBand) -> Int? {
        order.firstIndex(of: band)
    }

    /// Every control that is drawn AFTER the unbounded list — the defect itself, as a list.
    /// Empty is the passing state, and the paired existence below is what stops it passing on
    /// a layout with no controls in it.
    public static var controlsBelowTheList: [RecorderPageBand] {
        guard let listAt = position(of: unboundedList) else { return controls }
        return controls.filter { (position(of: $0) ?? Int.max) > listAt }
    }

    /// A band this type names and the layout never draws. A band that is declared and not laid
    /// out is a band whose content ships nowhere, which is the other way a control disappears.
    public static var bandsNotLaidOut: [RecorderPageBand] {
        RecorderPageBand.allCases.filter { !order.contains($0) }
    }
}
