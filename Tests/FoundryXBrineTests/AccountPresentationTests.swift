import XCTest
@testable import FoundryXKit

/// The Settings → Account identity block. Signing out must be VISIBLE (the row
/// flips to a signed-out affordance) and the account must be shown clearly above
/// the sign-out button — the two things the user asked for.
final class AccountPresentationTests: XCTestCase {
    func testSignedOutShowsNotSignedIn() {
        let p = AccountPresentation.make(signedIn: false, email: "x@y.com", name: "X", provider: "google")
        XCTAssertFalse(p.isSignedIn)
        XCTAssertEqual(p.primary, "Not signed in")
        XCTAssertNil(p.secondary)
        XCTAssertNil(p.providerLine)
    }

    func testGoogleWithNameShowsNameOverEmail() {
        let p = AccountPresentation.make(signedIn: true, email: "nick@goforgeit.com", name: "Nick Rinard", provider: "google")
        XCTAssertTrue(p.isSignedIn)
        XCTAssertEqual(p.primary, "Nick Rinard")
        XCTAssertEqual(p.secondary, "nick@goforgeit.com")
        XCTAssertEqual(p.providerLine, "Signed in with Google")
    }

    func testGoogleWithoutNameShowsEmailAsPrimary() {
        let p = AccountPresentation.make(signedIn: true, email: "nick@goforgeit.com", name: nil, provider: "google")
        XCTAssertEqual(p.primary, "nick@goforgeit.com")
        XCTAssertNil(p.secondary)
        XCTAssertEqual(p.providerLine, "Signed in with Google")
    }

    func testMicrosoftAndAppleProviderLabels() {
        XCTAssertEqual(AccountPresentation.make(signedIn: true, email: "a@b.com", name: nil, provider: "microsoft").providerLine,
                       "Signed in with Microsoft")
        XCTAssertEqual(AccountPresentation.make(signedIn: true, email: "a@b.com", name: nil, provider: "apple").providerLine,
                       "Signed in with Apple")
    }

    func testUnknownOrMissingProviderHasNoProviderLine() {
        XCTAssertNil(AccountPresentation.make(signedIn: true, email: "a@b.com", name: nil, provider: nil).providerLine)
        XCTAssertNil(AccountPresentation.make(signedIn: true, email: "a@b.com", name: nil, provider: "").providerLine)
    }

    func testSignedInWithoutEmailFallsBackToSignedIn() {
        let p = AccountPresentation.make(signedIn: true, email: nil, name: nil, provider: nil)
        XCTAssertTrue(p.isSignedIn)
        XCTAssertEqual(p.primary, "Signed in")
        XCTAssertNil(p.secondary)
    }

    func testWhitespaceNameIsIgnored() {
        let p = AccountPresentation.make(signedIn: true, email: "a@b.com", name: "   ", provider: "google")
        XCTAssertEqual(p.primary, "a@b.com")
        XCTAssertNil(p.secondary)
    }

    func testNameEqualToEmailDoesNotDuplicate() {
        let p = AccountPresentation.make(signedIn: true, email: "a@b.com", name: "a@b.com", provider: "google")
        XCTAssertEqual(p.primary, "a@b.com")
        XCTAssertNil(p.secondary)
    }
}
