import XCTest
@testable import Jaca

final class CloudLabelOrderingTests: XCTestCase {

    func testFavoritesPinnedToTopThenRestSorted() {
        let keys = ["region", "env", "user_id", "version"]
        let favorites = ["user_id", "env"]
        XCTAssertEqual(
            CloudLabelOrdering.ordered(keys: keys, favorites: favorites),
            ["env", "user_id", "region", "version"]   // favorites sorted, then rest sorted
        )
    }

    func testNoFavoritesJustSorted() {
        XCTAssertEqual(
            CloudLabelOrdering.ordered(keys: ["b", "a", "c"], favorites: []),
            ["a", "b", "c"]
        )
    }

    func testStaleFavoritesDropped() {
        // A favorite that's no longer detected isn't shown.
        XCTAssertEqual(
            CloudLabelOrdering.ordered(keys: ["env"], favorites: ["env", "gone"]),
            ["env"]
        )
    }

    func testAllFavorites() {
        XCTAssertEqual(
            CloudLabelOrdering.ordered(keys: ["z", "a"], favorites: ["z", "a"]),
            ["a", "z"]
        )
    }
}
