import XCTest
@testable import PalettePlatform

final class AllSpacesWallpaperTests: XCTestCase {
    private let picture = "/Users/x/wallpapers/one.jpg"

    private func configuration(for path: String) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: ["type": "imageFile", "url": ["relative": "file://\(path)"]],
            format: .binary, options: 0
        )
    }

    private func configurationData(_ data: Data) -> String? {
        guard let blob = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
              let url = blob["url"] as? [String: Any] else { return nil }
        return url["relative"] as? String
    }

    private func entry(_ path: String?) throws -> [String: Any] {
        var desktop: [String: Any] = ["LastSet": Date(timeIntervalSince1970: 0)]
        if let path {
            desktop["Content"] = ["Choices": [["Configuration": try configuration(for: path)]]]
        } else {
            desktop["Content"] = ["Choices": [["Configuration": Data()]]]
        }
        return ["Type": "individual", "Desktop": desktop]
    }

    private func store() throws -> Data {
        let root: [String: Any] = [
            "Spaces": [
                "A": ["Displays": ["D1": try entry(picture)]],
                "B": ["Displays": ["D2": try entry("/Users/x/wallpapers/other.jpg")]],
                "C": ["Displays": ["D1": try entry(nil)]],
            ],
            "Displays": ["D1": try entry(picture)],
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
                guard let path = configurationData(blob) else { continue } // non-file choice
                XCTAssertEqual(path, "file://\(picture)", "\(space)/\(display) still points elsewhere")
            }
        }
        let displays = try XCTUnwrap(root["Displays"] as? [String: Any])
        let desktop = try XCTUnwrap((displays["D1"] as? [String: Any])?["Desktop"] as? [String: Any])
        let blob = try XCTUnwrap(((desktop["Content"] as? [String: Any])?["Choices"] as? [[String: Any]])?.first?["Configuration"] as? Data)
        XCTAssertEqual(configurationData(blob), "file://\(picture)")
        XCTAssertEqual(AllSpacesWallpaper.count(in: rewritten), 3)
    }

    /// A Space whose choice cannot be retargeted still ends up on the same
    /// picture as the rest: the canonical entry is copied over it.
    func testUnusualEntriesAdoptTheCanonicalPicture() throws {
        let rewritten = try XCTUnwrap(try AllSpacesWallpaper.rewrite(try store(), picturePath: picture))
        let root = try decoded(rewritten)
        let spaces = try XCTUnwrap(root["Spaces"] as? [String: Any])
        let body = try XCTUnwrap(spaces["C"] as? [String: Any])
        let displays = try XCTUnwrap(body["Displays"] as? [String: Any])
        let desktop = try XCTUnwrap((displays["D1"] as? [String: Any])?["Desktop"] as? [String: Any])
        let choices = try XCTUnwrap((desktop["Content"] as? [String: Any])?["Choices"] as? [[String: Any]])
        let blob = try XCTUnwrap(choices.first?["Configuration"] as? Data)
        XCTAssertEqual(configurationData(blob), "file://\(picture)")
    }
}
