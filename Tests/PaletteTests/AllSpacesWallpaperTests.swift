import XCTest
@testable import PalettePlatform

final class AllSpacesWallpaperTests: XCTestCase {
    private let picture = "/Users/x/wallpapers/one.jpg"

    private func configuration(for path: String) -> Data {
        Data("bplist00 file://\(path)\u{0}".utf8)
    }

    private func entry(_ path: String?) -> [String: Any] {
        var desktop: [String: Any] = ["LastSet": Date(timeIntervalSince1970: 0)]
        if let path {
            desktop["Content"] = ["Choices": [["Configuration": configuration(for: path)]]]
        } else {
            desktop["Content"] = ["Choices": [["Configuration": Data()]]]
        }
        return ["Type": "individual", "Desktop": desktop]
    }

    private func store() throws -> Data {
        let root: [String: Any] = [
            "Spaces": [
                "A": ["Displays": ["D1": entry(picture)]],
                "B": ["Displays": ["D2": entry("/Users/x/wallpapers/other.jpg")]],
                "C": ["Displays": ["D1": entry(nil)]],
            ],
            "Displays": ["D1": entry(picture)],
        ]
        return try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
    }

    private func decoded(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                as? [String: Any]
        )
    }

    func testEverySpaceAndDisplayGetsTheChosenPicture() throws {
        let rewritten = try XCTUnwrap(
            try AllSpacesWallpaper.rewrite(try store(), picturePath: picture)
        )
        let root = try decoded(rewritten)
        let spaces = try XCTUnwrap(root["Spaces"] as? [String: Any])
        for (space, body) in spaces {
            let displays = try XCTUnwrap((body as? [String: Any])?["Displays"] as? [String: Any])
            for (display, raw) in displays {
                let desktop = try XCTUnwrap((raw as? [String: Any])?["Desktop"] as? [String: Any])
                let choices = try XCTUnwrap((desktop["Content"] as? [String: Any])?["Choices"] as? [[String: Any]])
                let blob = try XCTUnwrap(choices.first?["Configuration"] as? Data)
                XCTAssertTrue(
                    blob.range(of: Data("file://\(picture)".utf8)) != nil,
                    "\(space)/\(display) still points elsewhere"
                )
            }
        }
        let displays = try XCTUnwrap(root["Displays"] as? [String: Any])
        let desktop = try XCTUnwrap((displays["D1"] as? [String: Any])?["Desktop"] as? [String: Any])
        let blob = try XCTUnwrap(((desktop["Content"] as? [String: Any])?["Choices"] as? [[String: Any]])?.first?["Configuration"] as? Data)
        XCTAssertTrue(blob.range(of: Data("file://\(picture)".utf8)) != nil)
        XCTAssertEqual(AllSpacesWallpaper.count(in: rewritten), 3)
    }

    func testAPictureThatIsNotInTheStoreChangesNothing() throws {
        let original = try store()
        XCTAssertNil(try AllSpacesWallpaper.rewrite(original, picturePath: "/nope.jpg"))
    }
}
