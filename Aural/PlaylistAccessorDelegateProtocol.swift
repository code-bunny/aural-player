import Foundation

/*
    Contract for a middleman/delegate that relays read-only operations to the playlist
 */
protocol PlaylistAccessorDelegateProtocol {
    
    // Retrieve all tracks
    func getTracks() -> [Track]
    
    // Read the track at a given index. Nil if invalid index is specified.
    func peekTrackAt(_ index: Int?) -> IndexedTrack?
    
    func getGroupingInfoForTrack(_ track: Track, _ groupType: GroupType) -> GroupedTrack
    
    // Returns the size (i.e. total number of tracks) of the playlist
    func size() -> Int
    
    // Returns the total duration of the playlist tracks
    func totalDuration() -> Double
    
    // Returns a summary of the playlist - both size and total duration
    func summary() -> (size: Int, totalDuration: Double)
    
    // Searches the playlist, given certain query parameters, and returns all matching results
    func search(_ searchQuery: SearchQuery) -> SearchResults
    
    // Searches the playlist, given certain query parameters, and returns all matching results
    func search(_ searchQuery: SearchQuery, _ groupType: GroupType) -> SearchResults
    
    func getGroupAt(_ type: GroupType, _ index: Int) -> Group
    
    func getNumberOfGroups(_ type: GroupType) -> Int
    
    func getGroupingInfoForTrack(_ type: GroupType, _ track: Track) -> GroupedTrack
    
    func getIndexOf(_ group: Group) -> Int
    
    func displayNameFor(_ type: GroupType, _ track: Track) -> String
}
