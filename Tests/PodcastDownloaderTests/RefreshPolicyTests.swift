import XCTest
@testable import PodcastDownloader

final class RefreshPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testNeverRefreshedIsDue() {
        XCTAssertTrue(RefreshPolicy.isDue(lastFullRefresh: nil, minimumMinutes: 60, now: now))
    }

    func testWithinIntervalIsNotDue() {
        let last = now.addingTimeInterval(-59 * 60)
        XCTAssertFalse(RefreshPolicy.isDue(lastFullRefresh: last, minimumMinutes: 60, now: now))
    }

    func testAtOrPastIntervalIsDue() {
        XCTAssertTrue(RefreshPolicy.isDue(lastFullRefresh: now.addingTimeInterval(-60 * 60), minimumMinutes: 60, now: now))
        XCTAssertTrue(RefreshPolicy.isDue(lastFullRefresh: now.addingTimeInterval(-5 * 3600), minimumMinutes: 60, now: now))
    }

    func testEveryLaunchIsAlwaysDue() {
        XCTAssertTrue(RefreshPolicy.isDue(lastFullRefresh: now, minimumMinutes: 0, now: now))
    }

    func testNeverDisablesAutomaticRefresh() {
        XCTAssertFalse(RefreshPolicy.isDue(lastFullRefresh: nil, minimumMinutes: RefreshPolicy.never, now: now))
        XCTAssertFalse(RefreshPolicy.isDue(lastFullRefresh: now.addingTimeInterval(-86_400 * 30), minimumMinutes: RefreshPolicy.never, now: now))
    }

    func testEveryOptionHasALabel() {
        for option in RefreshPolicy.options {
            XCTAssertEqual(RefreshPolicy.label(forMinutes: option.minutes), option.label)
        }
    }
}
