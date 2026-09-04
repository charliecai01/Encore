import Foundation

public extension String {
    /// YouTube prefixes some playlist ids with "VL" in browse contexts; strip it
    /// to get the id the library/playlist-edit endpoints expect.
    var strippingPlaylistVLPrefix: String {
        hasPrefix("VL") ? String(dropFirst(2)) : self
    }
}
