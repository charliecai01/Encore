import XCTest
@testable import EncoreCore

/// Album/playlist headers can carry BOTH the cover (`thumbnail`) and the
/// artist's avatar (`straplineThumbnail`). A recursive thumbnail search finds
/// the avatar first, which put a promo photo on the album page — and on every
/// track row and queue entry, since album tracks inherit the header thumb.
final class HeaderArtworkTests: XCTestCase {
    /// straplineThumbnail deliberately precedes thumbnail, as YouTube sends it.
    private let headerJSON = """
    {
      "musicResponsiveHeaderRenderer": {
        "straplineTextOne": { "runs": [{ "text": "David Tao" }] },
        "straplineThumbnail": {
          "musicThumbnailRenderer": {
            "thumbnail": { "thumbnails": [{ "url": "https://yt3.googleusercontent.com/AVATAR=w544-h544", "width": 544, "height": 544 }] }
          }
        },
        "subtitle": { "runs": [{ "text": "Album" }, { "text": " • " }, { "text": "2014" }] },
        "thumbnail": {
          "musicThumbnailRenderer": {
            "thumbnail": { "thumbnails": [{ "url": "https://yt3.googleusercontent.com/COVER=w544-h544", "width": 544, "height": 544 }] }
          }
        },
        "title": { "runs": [{ "text": "Soul Power (Live Concert)" }] }
      }
    }
    """

    func testHeaderPrefersCoverOverArtistAvatar() {
        let root = JSONValue.parse(Data(headerJSON.utf8))
        let info = P.headerInfo(from: root)
        XCTAssertEqual(info.title, "Soul Power (Live Concert)")
        XCTAssertEqual(info.thumb?.absoluteString,
                       "https://yt3.googleusercontent.com/COVER=w544-h544",
                       "header used the artist avatar instead of the album cover")
    }

    /// Headers without a strapline must still resolve their cover.
    func testHeaderWithoutStraplineStillFindsCover() {
        let json = """
        {
          "musicResponsiveHeaderRenderer": {
            "title": { "runs": [{ "text": "Some Album" }] },
            "thumbnail": {
              "musicThumbnailRenderer": {
                "thumbnail": { "thumbnails": [{ "url": "https://example.com/COVER", "width": 1, "height": 1 }] }
              }
            }
          }
        }
        """
        let info = P.headerInfo(from: JSONValue.parse(Data(json.utf8)))
        XCTAssertEqual(info.thumb?.absoluteString, "https://example.com/COVER")
    }

    /// Album tracks inherit the header thumb — so the cover must propagate.
    func testAlbumTracksInheritCoverNotAvatar() {
        let json = """
        {
          "musicResponsiveHeaderRenderer": {
            "straplineThumbnail": {
              "musicThumbnailRenderer": {
                "thumbnail": { "thumbnails": [{ "url": "https://example.com/AVATAR", "width": 1, "height": 1 }] }
              }
            },
            "thumbnail": {
              "musicThumbnailRenderer": {
                "thumbnail": { "thumbnails": [{ "url": "https://example.com/COVER", "width": 1, "height": 1 }] }
              }
            },
            "title": { "runs": [{ "text": "A" }] }
          },
          "musicPlaylistShelfRenderer": {
            "contents": [
              {
                "musicResponsiveListItemRenderer": {
                  "playlistItemData": { "videoId": "vid1" },
                  "flexColumns": [
                    { "musicResponsiveListItemFlexColumnRenderer": { "text": { "runs": [{ "text": "Track One" }] } } }
                  ]
                }
              }
            ]
          }
        }
        """
        let page = P.collectionPage(from: JSONValue.parse(Data(json.utf8)), isAlbum: true)
        XCTAssertEqual(page.thumbnailURL?.absoluteString, "https://example.com/COVER")
        XCTAssertEqual(page.tracks.first?.thumbnailURL?.absoluteString, "https://example.com/COVER",
                       "album track inherited the artist avatar")
    }
}
