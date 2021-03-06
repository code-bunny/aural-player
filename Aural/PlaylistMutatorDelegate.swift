import Foundation

/*
    Concrete implementation of PlaylistMutatorDelegateProtocol
 */
class PlaylistMutatorDelegate: PlaylistMutatorDelegateProtocol, MessageSubscriber {
    
    // The actual playlist
    private let playlist: PlaylistCRUDProtocol
    
    // The actual playback sequence
    private let playbackSequencer: PlaybackSequencerProtocol
    
    // A set of all observers/listeners that are interested in changes to the playlist
    private let changeListeners: [PlaylistChangeListener]
    
    // A player with basic playback functionality (used for autoplay)
    private let player: BasicPlaybackDelegateProtocol
    
    // Persistent playlist state (used upon app startup)
    private let playlistState: PlaylistState
    
    // User preferences (used for autoplay)
    private let preferences: Preferences
    
    init(_ playlist: PlaylistCRUDProtocol, _ playbackSequencer: PlaybackSequencerProtocol, _ player: BasicPlaybackDelegateProtocol, _ playlistState: PlaylistState, _ preferences: Preferences, _ changeListeners: [PlaylistChangeListener]) {
        
        self.playlist = playlist
        self.playbackSequencer = playbackSequencer
        
        self.player = player
        
        self.playlistState = playlistState
        self.preferences = preferences
        
        self.changeListeners = changeListeners
        
        // Subscribe for message notifications
        SyncMessenger.subscribe(.appLoadedNotification, subscriber: self)
        SyncMessenger.subscribe(.appReopenedNotification, subscriber: self)
    }
    
    func addFiles(_ files: [URL]) {
        
        let autoplay: Bool = self.preferences.autoplayAfterAddingTracks
        let interruptPlayback: Bool = self.preferences.autoplayAfterAddingOption == .always
        
        addFiles_async(files, AutoplayOptions(autoplay, interruptPlayback))
    }
    
    // Adds files to the playlist asynchronously, emitting event notifications as the work progresses
    private func addFiles_async(_ files: [URL], _ autoplayOptions: AutoplayOptions) {
        
        // Move to a background thread to unblock the main thread
        DispatchQueue.global(qos: .userInteractive).async {
            
            // Progress
            let progress = TrackAddOperationProgress(0, files.count, [InvalidTrackError](), false)
            
            AsyncMessenger.publishMessage(StartedAddingTracksAsyncMessage.instance)
            
            self.addFiles_sync(files, autoplayOptions, progress)
            
            AsyncMessenger.publishMessage(DoneAddingTracksAsyncMessage.instance)
            
            // If errors > 0, send AsyncMessage to UI
            if (progress.errors.count > 0) {
                AsyncMessenger.publishMessage(TracksNotAddedAsyncMessage(progress.errors))
            }
        }
    }
    
    /* 
        Adds a bunch of files synchronously.
     
        The autoplayOptions argument encapsulates all autoplay options.
     
        The progress argument indicates current progress.
     */
    private func addFiles_sync(_ files: [URL], _ autoplayOptions: AutoplayOptions, _ progress: TrackAddOperationProgress) {
        
        if (files.count > 0) {
            
            for _file in files {
                
                // Playlists might contain broken file references
                if (!FileSystemUtils.fileExists(_file)) {
                    progress.errors.append(FileNotFoundError(_file))
                    continue
                }
                
                // Always resolve sym links and aliases before reading the file
                let resolvedFileInfo = FileSystemUtils.resolveTruePath(_file)
                let file = resolvedFileInfo.resolvedURL
                
                if (resolvedFileInfo.isDirectory) {
                    
                    // Directory
                    addDirectory(file, autoplayOptions, progress)
                    
                } else {
                    
                    // Single file - playlist or track
                    let fileExtension = file.pathExtension.lowercased()
                    
                    if (AppConstants.supportedPlaylistFileExtensions.contains(fileExtension)) {
                        
                        // Playlist
                        addPlaylist(file, autoplayOptions, progress)
                        
                    } else if (AppConstants.supportedAudioFileExtensions.contains(fileExtension)) {
                        
                        // Track
                        do {
                            
                            progress.tracksAdded += 1
                            
                            let progressMsg = TrackAddedMessageProgress(progress.tracksAdded, progress.totalTracks)
                            let index = try addTrack(file, progressMsg)
                            
                            if (autoplayOptions.autoplay && !progress.autoplayed && index >= 0) {
                                
                                self.autoplay(index, autoplayOptions.interruptPlayback)
                                progress.autoplayed = true
                            }
                            
                        }  catch let error {
                            
                            if (error is InvalidTrackError) {
                                progress.errors.append(error as! InvalidTrackError)
                            }
                        }
                    }
                }
            }
        }
    }
    
    // Expands a playlist into individual tracks
    private func addPlaylist(_ playlistFile: URL, _ autoplayOptions: AutoplayOptions, _ progress: TrackAddOperationProgress) {
        
        let loadedPlaylist = PlaylistIO.loadPlaylist(playlistFile)
        if (loadedPlaylist != nil) {
            
            progress.totalTracks -= 1
            progress.totalTracks += (loadedPlaylist?.tracks.count)!
            
            addFiles_sync(loadedPlaylist!.tracks, autoplayOptions, progress)
        }
    }
    
    // Expands a directory into individual tracks (and subdirectories)
    private func addDirectory(_ dir: URL, _ autoplayOptions: AutoplayOptions, _ progress: TrackAddOperationProgress) {
        
        let dirContents = FileSystemUtils.getContentsOfDirectory(dir)
        if (dirContents != nil) {
            
            progress.totalTracks -= 1
            progress.totalTracks += (dirContents?.count)!
            
            // Add them
            addFiles_sync(dirContents!, autoplayOptions, progress)
        }
    }
    
    // Adds a single track to the playlist. Returns index of newly added track
    private func addTrack(_ file: URL, _ progress: TrackAddedMessageProgress) throws -> Int {
        
        let track = Track(file)
        TrackIO.loadDisplayInfo(track)
        
        let trackAddResult = playlist.addTrack(track)
        
        // index >= 0 indicates success in adding the track to the playlist
        if let result = trackAddResult {
            
            let index = result.flatPlaylistResult
            let groupResults = result.groupingPlaylistResults

            notifyTrackAdded(track, index, groupResults, progress)
            
            // TODO: Do I need to do this update async ?
            
            // Load display info async (ID3 info, duration)
            DispatchQueue.global(qos: .userInitiated).async {
                
                TrackIO.loadDuration(track)
                
                var groupInfo = [GroupType: GroupedTrack]()
                groupResults.forEach({groupInfo[$0.key] = $0.value.track})
            
                AsyncMessenger.publishMessage(TrackUpdatedAsyncMessage(index, groupInfo))
            }
            
            return index
        }
        
        return -1
    }
    
    // Publishes a notification that a new track has been added to the playlist
    private func notifyTrackAdded(_ track: Track, _ trackIndex: Int, _ groupInfo: [GroupType: GroupedTrackAddResult], _ progress: TrackAddedMessageProgress) {
        
//        NSLog("\tUpdating UI for %@ added", track.conciseDisplayName)
//        DispatchQueue.main.sync {
//            SyncMessenger.publishNotification(TrackAddedNotification(trackIndex, groupInfo, progress))
//        }
        
        AsyncMessenger.publishMessage(TrackAddedAsyncMessage(trackIndex, groupInfo, progress))
        
//        NSLog("\tDone updating UI for %@ added", track.conciseDisplayName)
        
        // Also notify the listeners directly
        changeListeners.forEach({$0.trackAdded(track)})
    }
    
    // Performs autoplay, by delegating a playback request to the player
    private func autoplay(_ index: Int, _ interruptPlayback: Bool) {
        
        DispatchQueue.main.async {
            
            let oldTrack = self.playbackSequencer.getPlayingTrack()
            
            do {
                
                let playingTrack = try self.player.play(index, interruptPlayback)
                
                // Notify the UI that a track has started playing
                if (playingTrack != nil) {
                    AsyncMessenger.publishMessage(TrackChangedAsyncMessage(oldTrack, playingTrack))
                }
                
            } catch let error {
                
                if (error is InvalidTrackError) {
                    AsyncMessenger.publishMessage(TrackNotPlayedAsyncMessage(oldTrack, error as! InvalidTrackError))
                }
            }
        }
    }
    
    func removeTracks(_ indexes: [Int]) {
        
        let results: RemoveOperationResults = playlist.removeTracks(IndexSet(indexes))
        
        let message = TracksRemovedAsyncMessage(results)
        AsyncMessenger.publishMessage(message)
        
        changeListeners.forEach({$0.tracksRemoved(indexes, [])})
    }
    
    func removeTracksAndGroups(_ tracks: [Track], _ groups: [Group], _ groupType: GroupType) {
        
        let results = playlist.removeTracksAndGroups(tracks, groups, groupType)
        
        let message = TracksRemovedAsyncMessage(results)
        AsyncMessenger.publishMessage(message)
        
        changeListeners.forEach({$0.tracksRemoved(results.flatPlaylistResults.filter({$0 >= 0}), [])})
    }
    
    func moveTracksUp(_ indexes: IndexSet) -> ItemMovedResults {
        return tracksMoved(indexes, playlist.moveTracksUp(indexes))
    }
    
    func moveTracksDown(_ indexes: IndexSet) -> ItemMovedResults {
        return tracksMoved(indexes, playlist.moveTracksDown(indexes))
    }
    
    private func tracksMoved(_ indexes: IndexSet, _ results: ItemMovedResults) -> ItemMovedResults {
        
        // Note down which track was playing, if any
        let playingTrack = playbackSequencer.getPlayingTrack()
        let oldPlayingTrackIndex = playingTrack?.index
        
        // Update the playing track index
        let newPlayingTrackIndex = oldPlayingTrackIndex == nil ? nil : (indexes.contains(oldPlayingTrackIndex!) ? findNewIndexFor(oldPlayingTrackIndex!, results) : playlist.indexOfTrack(playingTrack!.track))
        
        // TODO: Do this more smartly (only part of the playlist has been reordered)
        // Notify listeners of the reordering of tracks
        changeListeners.forEach({$0.playlistReordered(newPlayingTrackIndex)})
        
        return results
    }
    
    private func findNewIndexFor(_ oldIndex: Int, _ results: ItemMovedResults) -> Int {
        
        var newIndex: Int = -1
        
        results.results.forEach({
        
            let trackMovedResult = $0 as! TrackMovedResult
            if trackMovedResult.oldTrackIndex == oldIndex {
                newIndex = trackMovedResult.newTrackIndex
            }
        })
        
        return newIndex
    }
    
    func moveTracksAndGroupsUp(_ tracks: [Track], _ groups: [Group], _ groupType: GroupType) -> ItemMovedResults {
        return playlist.moveTracksAndGroupsUp(tracks, groups, groupType)
    }
    
    func moveTracksAndGroupsDown(_ tracks: [Track], _ groups: [Group], _ groupType: GroupType) -> ItemMovedResults {
        return playlist.moveTracksAndGroupsDown(tracks, groups, groupType)
    }
    
    func clear() {
        
        playlist.clear()
        changeListeners.forEach({$0.playlistCleared()})
    }
    
    func sort(_ sort: Sort) {
        
        let playingTrack = playbackSequencer.getPlayingTrack()
        
        playlist.sort(sort)
        
        let newCursor = playingTrack == nil ? nil : playlist.indexOfTrack(playingTrack!.track)
        changeListeners.forEach({$0.playlistReordered(newCursor)})
    }
    
    func sort(_ sort: Sort, _ groupType: GroupType) {
        playlist.sort(sort, groupType)
    }
    
    func consumeNotification(_ notification: NotificationMessage) {
        
        if (notification is AppLoadedNotification) {
            
            let msg = notification as! AppLoadedNotification
            let filesToOpen = msg.filesToOpen
            
            // Check if any launch parameters were specified
            if (!filesToOpen.isEmpty) {
                
                // Launch parameters  specified, override playlist saved state and add file paths in params to playlist
                addFiles_async(filesToOpen, AutoplayOptions(true, true))
                
            } else if (preferences.playlistOnStartup == .rememberFromLastAppLaunch) {
                
                // No launch parameters specified, load playlist saved state if "Remember state from last launch" preference is selected
                addFiles_async(playlistState.tracks, AutoplayOptions(preferences.autoplayOnStartup, true))
            }
            
            return
        }
        
        if (notification is AppReopenedNotification) {
            
            let msg = notification as! AppReopenedNotification
            
            // When a duplicate notification is sent, don't autoplay ! Otherwise, always autoplay.
            addFiles_async(msg.filesToOpen, AutoplayOptions(!msg.isDuplicateNotification, true))
            
            return
        }
    }
    
    func processRequest(_ request: RequestMessage) -> ResponseMessage {
        return EmptyResponse.instance
    }
    
    func reorderTracks(_ reorderOperations: [PlaylistReorderOperation]) {
        
        let playingTrack = playbackSequencer.getPlayingTrack()
        
        playlist.reorderTracks(reorderOperations)
        
        let newCursor = playingTrack == nil ? nil : playlist.indexOfTrack(playingTrack!.track)
        changeListeners.forEach({$0.playlistReordered(newCursor)})
    }
    
    func reorderTracks(_ reorderOperations: [GroupingPlaylistReorderOperation], _ groupType: GroupType) {
        playlist.reorderTracks(reorderOperations, groupType)
    }
}

// Indicates current progress for an operation that adds tracks to the playlist
class TrackAddOperationProgress {

    var tracksAdded: Int
    var totalTracks: Int
    var errors: [InvalidTrackError]
    var autoplayed: Bool

    init(_ tracksAdded: Int, _ totalTracks: Int, _ errors: [InvalidTrackError], _ autoplayed: Bool) {
        
        self.tracksAdded = tracksAdded
        self.totalTracks = totalTracks
        self.errors = errors
        self.autoplayed = autoplayed
    }
}

// Encapsulates all autoplay options
class AutoplayOptions {
    
    // Whether or not autoplay is requested
    var autoplay: Bool
    
    // Whether or not existing track playback should be interrupted, to perform autoplay
    var interruptPlayback: Bool
    
    init(_ autoplay: Bool,
         _ interruptPlayback: Bool) {
        
        self.autoplay = autoplay
        self.interruptPlayback = interruptPlayback
    }
}
