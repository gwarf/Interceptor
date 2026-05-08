// PRD-66 Domain 13 — MusicKit. Catalog macOS 12+; library + ApplicationMusicPlayer
// macOS 14+. SystemMusicPlayer is iOS-only — bridge surfaces a structured note.
// References: apple-developer-docs/MusicKit/{MusicCatalogSearchRequest,
// MusicLibraryRequest,ApplicationMusicPlayer,MusicAuthorization,Song,Album,...}.md.

import Foundation
#if canImport(MusicKit)
import MusicKit
#endif

final class MusicDomain: DomainHandler, @unchecked Sendable {
    func handle(_ command: String, action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        let sub = action["sub"] as? String ?? command
        if #available(macOS 12, *) {
            switch sub {
            case "status":              status(completion: completion)
            case "request":              requestAuth(completion: completion)
            case "subscription":        subscription(completion: completion)
            // Catalog verbs (search/search-suggest/charts/recommendations and
            // the by-catalog-id fetchers) require an Apple Developer MusicKit
            // team key, which interceptor-bridge does not ship with. Removed
            // from the public surface — surface a structured "unknown verb"
            // with hint instead of the opaque "Failed to request developer
            // token" the catalog APIs would return.
            case "search", "search-suggest", "charts", "recommendations",
                 "song", "album", "artist", "playlist":
                completion(WireFormat.error("music.\(sub): removed — Apple Music catalog APIs require a paid Apple Developer MusicKit team key that this bridge does not ship with. Use library / library-search / playback verbs instead."))
            case "library":             library(action, completion: completion)
            case "library-search":      librarySearch(action, completion: completion)
            case "play":                play(action, completion: completion)
            case "pause":               pause(completion: completion)
            case "resume":              resume(completion: completion)
            case "stop":                stopPlayback(completion: completion)
            case "next":                next(completion: completion)
            case "previous":            previous(completion: completion)
            case "seek":                seek(action, completion: completion)
            case "queue":               queueSnapshot(completion: completion)
            case "repeat":              setRepeat(action, completion: completion)
            case "shuffle":             setShuffle(action, completion: completion)
            case "now-playing":         nowPlaying(completion: completion)
            default:                    completion(WireFormat.error("music.\(sub) — unknown verb"))
            }
        } else {
            completion(WireFormat.success([
                "available": false,
                "framework": "MusicKit",
                "note": "MusicKit catalog requires macOS 12.0+ (library + ApplicationMusicPlayer macOS 14+).",
            ]))
        }
    }

    // MARK: - Auth / status

    @available(macOS 12, *)
    private func status(completion: @escaping @Sendable ([String: Any]) -> Void) {
        var resp: [String: Any] = [
            "authorization": String(describing: MusicAuthorization.currentStatus),
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "frameworkAvailable": true,
        ]
        if #available(macOS 14, *) {
            resp["applicationPlayerAvailable"] = true
            resp["libraryAvailable"] = true
        } else {
            resp["applicationPlayerAvailable"] = false
            resp["libraryAvailable"] = false
        }
        completion(WireFormat.success(resp))
    }

    @available(macOS 12, *)
    private func requestAuth(completion: @escaping @Sendable ([String: Any]) -> Void) {
        Task {
            let s = await MusicAuthorization.request()
            completion(WireFormat.success(["authorization": String(describing: s)]))
        }
    }

    @available(macOS 12, *)
    private func subscription(completion: @escaping @Sendable ([String: Any]) -> Void) {
        Task {
            do {
                let sub = try await MusicSubscription.current
                completion(WireFormat.success([
                    "canBecomeSubscriber": sub.canBecomeSubscriber,
                    "canPlayCatalogContent": sub.canPlayCatalogContent,
                    "hasCloudLibraryEnabled": sub.hasCloudLibraryEnabled,
                ]))
            } catch {
                completion(WireFormat.error("music.subscription: \(error.localizedDescription)"))
            }
        }
    }

    // MARK: - Search

    @available(macOS 12, *)
    private func parseTypes(_ raw: String?) -> [any MusicCatalogSearchable.Type] {
        let defaults: [any MusicCatalogSearchable.Type] = [Song.self, Album.self, Artist.self, Playlist.self]
        guard let raw = raw else { return defaults }
        var out: [any MusicCatalogSearchable.Type] = []
        for t in raw.split(separator: ",") {
            switch t.trimmingCharacters(in: .whitespaces) {
            case "song":     out.append(Song.self)
            case "album":    out.append(Album.self)
            case "artist":   out.append(Artist.self)
            case "playlist": out.append(Playlist.self)
            case "curator":  out.append(Curator.self)
            // `Genre` does not conform to MusicCatalogSearchable on macOS;
            // omitted to keep the set type-correct.
            default: break
            }
        }
        return out.isEmpty ? defaults : out
    }

    @available(macOS 12, *)
    private func search(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard let term = action["term"] as? String else { completion(WireFormat.error("music.search: <term> required")); return }
        var request = MusicCatalogSearchRequest(term: term, types: parseTypes(action["types"] as? String))
        if let limit = action["limit"] as? Int { request.limit = limit }
        if let offset = action["offset"] as? Int { request.offset = offset }
        if (action["top"] as? Bool) == true { request.includeTopResults = true }
        Task {
            do {
                let response = try await request.response()
                completion(WireFormat.success([
                    "term": term,
                    "songs":     response.songs.map { ["id": $0.id.rawValue, "title": $0.title, "artistName": $0.artistName] },
                    "albums":    response.albums.map { ["id": $0.id.rawValue, "title": $0.title, "artistName": $0.artistName] },
                    "artists":   response.artists.map { ["id": $0.id.rawValue, "name": $0.name] },
                    "playlists": response.playlists.map { ["id": $0.id.rawValue, "name": $0.name] },
                ]))
            } catch {
                completion(WireFormat.error("music.search: \(error.localizedDescription)"))
            }
        }
    }

    @available(macOS 12, *)
    private func searchSuggest(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard let term = action["term"] as? String else { completion(WireFormat.error("music.search-suggest: <term> required")); return }
        let request = MusicCatalogSearchSuggestionsRequest(term: term, includingTopResultsOfTypes: [Song.self, Album.self, Artist.self])
        Task {
            do {
                let response = try await request.response()
                completion(WireFormat.success([
                    "term": term,
                    "suggestions": response.suggestions.map { String(describing: $0) },
                ]))
            } catch {
                completion(WireFormat.error("music.search-suggest: \(error.localizedDescription)"))
            }
        }
    }

    @available(macOS 12, *)
    private func charts(completion: @escaping @Sendable ([String: Any]) -> Void) {
        let request = MusicCatalogChartsRequest(kinds: [.mostPlayed], types: [Song.self, Album.self])
        Task {
            do {
                let response = try await request.response()
                completion(WireFormat.success([
                    "songCharts": response.songCharts.map { ["title": $0.title, "items": $0.items.map { ["id": $0.id.rawValue, "title": $0.title] }] },
                    "albumCharts": response.albumCharts.map { ["title": $0.title, "items": $0.items.map { ["id": $0.id.rawValue, "title": $0.title] }] },
                ]))
            } catch {
                completion(WireFormat.error("music.charts: \(error.localizedDescription)"))
            }
        }
    }

    @available(macOS 12, *)
    private func recommendations(completion: @escaping @Sendable ([String: Any]) -> Void) {
        Task {
            do {
                let request = MusicPersonalRecommendationsRequest()
                let response = try await request.response()
                completion(WireFormat.success([
                    "recommendations": response.recommendations.map { ["title": $0.title as Any? ?? NSNull()] },
                ]))
            } catch {
                completion(WireFormat.error("music.recommendations: \(error.localizedDescription)"))
            }
        }
    }

    // MARK: - Library

    @available(macOS 14, *)
    private func libraryV14(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        let type = (action["type"] as? String) ?? "song"
        let limit = action["limit"] as? Int
        Task {
            do {
                switch type {
                case "song":
                    var req = MusicLibraryRequest<Song>()
                    if let limit = limit { req.limit = limit }
                    let response = try await req.response()
                    completion(WireFormat.success(["items": response.items.map { ["id": $0.id.rawValue, "title": $0.title, "artistName": $0.artistName] }]))
                case "album":
                    var req = MusicLibraryRequest<Album>()
                    if let limit = limit { req.limit = limit }
                    let response = try await req.response()
                    completion(WireFormat.success(["items": response.items.map { ["id": $0.id.rawValue, "title": $0.title, "artistName": $0.artistName] }]))
                case "artist":
                    var req = MusicLibraryRequest<Artist>()
                    if let limit = limit { req.limit = limit }
                    let response = try await req.response()
                    completion(WireFormat.success(["items": response.items.map { ["id": $0.id.rawValue, "name": $0.name] }]))
                case "playlist":
                    var req = MusicLibraryRequest<Playlist>()
                    if let limit = limit { req.limit = limit }
                    let response = try await req.response()
                    completion(WireFormat.success(["items": response.items.map { ["id": $0.id.rawValue, "name": $0.name] }]))
                case "track":
                    var req = MusicLibraryRequest<Track>()
                    if let limit = limit { req.limit = limit }
                    let response = try await req.response()
                    completion(WireFormat.success(["items": response.items.map { ["id": $0.id.rawValue, "title": $0.title] }]))
                default:
                    completion(WireFormat.error("music.library: unknown --type"))
                }
            } catch {
                completion(WireFormat.error("music.library: \(error.localizedDescription)"))
            }
        }
    }

    @available(macOS 12, *)
    private func library(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        if #available(macOS 14, *) { libraryV14(action, completion: completion); return }
        completion(WireFormat.success(["available": false, "note": "MusicLibraryRequest requires macOS 14+"]))
    }

    @available(macOS 14, *)
    private func librarySearchV14(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard let term = action["term"] as? String else { completion(WireFormat.error("music.library-search: <term> required")); return }
        var request = MusicLibrarySearchRequest(term: term, types: [Song.self, Album.self, Artist.self, Playlist.self])
        if let limit = action["limit"] as? Int { request.limit = limit }
        Task {
            do {
                let response = try await request.response()
                completion(WireFormat.success([
                    "term": term,
                    "songs":     response.songs.map { ["id": $0.id.rawValue, "title": $0.title] },
                    "albums":    response.albums.map { ["id": $0.id.rawValue, "title": $0.title] },
                    "artists":   response.artists.map { ["id": $0.id.rawValue, "name": $0.name] },
                    "playlists": response.playlists.map { ["id": $0.id.rawValue, "name": $0.name] },
                ]))
            } catch {
                completion(WireFormat.error("music.library-search: \(error.localizedDescription)"))
            }
        }
    }

    @available(macOS 12, *)
    private func librarySearch(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        if #available(macOS 14, *) { librarySearchV14(action, completion: completion); return }
        completion(WireFormat.success(["available": false, "note": "MusicLibrarySearchRequest requires macOS 14+"]))
    }

    // MARK: - Resource fetch by id

    @available(macOS 12, *)
    private func fetchById(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void, kind: String) {
        guard let id = action["id"] as? String else { completion(WireFormat.error("music.\(kind): <id> required")); return }
        Task {
            do {
                switch kind {
                case "song":
                    let req = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(id))
                    let resp = try await req.response()
                    if let s = resp.items.first {
                        completion(WireFormat.success([
                            "id": s.id.rawValue, "title": s.title, "artistName": s.artistName,
                            "albumTitle": s.albumTitle as Any? ?? NSNull(),
                            "duration": s.duration as Any? ?? NSNull(),
                            "isrc": s.isrc as Any? ?? NSNull(),
                            "genreNames": s.genreNames,
                        ]))
                    } else { completion(WireFormat.error("music.song: not found")) }
                case "album":
                    let req = MusicCatalogResourceRequest<Album>(matching: \.id, equalTo: MusicItemID(id))
                    let resp = try await req.response()
                    if let a = resp.items.first {
                        completion(WireFormat.success(["id": a.id.rawValue, "title": a.title, "artistName": a.artistName]))
                    } else { completion(WireFormat.error("music.album: not found")) }
                case "artist":
                    let req = MusicCatalogResourceRequest<Artist>(matching: \.id, equalTo: MusicItemID(id))
                    let resp = try await req.response()
                    if let a = resp.items.first {
                        completion(WireFormat.success(["id": a.id.rawValue, "name": a.name]))
                    } else { completion(WireFormat.error("music.artist: not found")) }
                case "playlist":
                    let req = MusicCatalogResourceRequest<Playlist>(matching: \.id, equalTo: MusicItemID(id))
                    let resp = try await req.response()
                    if let p = resp.items.first {
                        completion(WireFormat.success(["id": p.id.rawValue, "name": p.name]))
                    } else { completion(WireFormat.error("music.playlist: not found")) }
                default:
                    completion(WireFormat.error("music: unknown kind \(kind)"))
                }
            } catch {
                completion(WireFormat.error("music.\(kind): \(error.localizedDescription)"))
            }
        }
    }

    // MARK: - Playback

    @available(macOS 14, *)
    private func playV14(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        let songId = action["song"] as? String
        let albumId = action["album"] as? String
        let playlistId = action["playlist"] as? String
        Task {
            let player = ApplicationMusicPlayer.shared
            do {
                if let songId = songId {
                    let req = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(songId))
                    let resp = try await req.response()
                    guard let song = resp.items.first else { completion(WireFormat.error("music.play: song not found")); return }
                    player.queue = [song]
                } else if let albumId = albumId {
                    let req = MusicCatalogResourceRequest<Album>(matching: \.id, equalTo: MusicItemID(albumId))
                    let resp = try await req.response()
                    guard let album = resp.items.first else { completion(WireFormat.error("music.play: album not found")); return }
                    player.queue = [album]
                } else if let playlistId = playlistId {
                    let req = MusicCatalogResourceRequest<Playlist>(matching: \.id, equalTo: MusicItemID(playlistId))
                    let resp = try await req.response()
                    guard let p = resp.items.first else { completion(WireFormat.error("music.play: playlist not found")); return }
                    player.queue = [p]
                } else {
                    completion(WireFormat.error("music.play: --song / --album / --playlist required")); return
                }
                try await player.play()
                completion(WireFormat.success(["ok": true, "playbackStatus": String(describing: player.state.playbackStatus)]))
            } catch {
                completion(WireFormat.error("music.play: \(error.localizedDescription)"))
            }
        }
    }

    @available(macOS 12, *)
    private func play(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        if #available(macOS 14, *) { playV14(action, completion: completion); return }
        completion(WireFormat.success(["available": false, "note": "ApplicationMusicPlayer requires macOS 14+"]))
    }

    @available(macOS 14, *)
    private func playerV14() -> ApplicationMusicPlayer { ApplicationMusicPlayer.shared }

    @available(macOS 12, *)
    private func pause(completion: @escaping @Sendable ([String: Any]) -> Void) {
        if #available(macOS 14, *) { playerV14().pause(); completion(WireFormat.success(["ok": true])); return }
        completion(WireFormat.success(["available": false]))
    }

    @available(macOS 12, *)
    private func resume(completion: @escaping @Sendable ([String: Any]) -> Void) {
        if #available(macOS 14, *) { Task { try? await playerV14().play(); completion(WireFormat.success(["ok": true])) }; return }
        completion(WireFormat.success(["available": false]))
    }

    @available(macOS 12, *)
    private func stopPlayback(completion: @escaping @Sendable ([String: Any]) -> Void) {
        if #available(macOS 14, *) { playerV14().stop(); completion(WireFormat.success(["ok": true])); return }
        completion(WireFormat.success(["available": false]))
    }

    @available(macOS 12, *)
    private func next(completion: @escaping @Sendable ([String: Any]) -> Void) {
        if #available(macOS 14, *) { Task { try? await playerV14().skipToNextEntry(); completion(WireFormat.success(["ok": true])) }; return }
        completion(WireFormat.success(["available": false]))
    }

    @available(macOS 12, *)
    private func previous(completion: @escaping @Sendable ([String: Any]) -> Void) {
        if #available(macOS 14, *) { Task { try? await playerV14().skipToPreviousEntry(); completion(WireFormat.success(["ok": true])) }; return }
        completion(WireFormat.success(["available": false]))
    }

    @available(macOS 12, *)
    private func seek(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        guard let t = action["time"] as? Double else { completion(WireFormat.error("music.seek: --time <seconds> required")); return }
        if #available(macOS 14, *) {
            playerV14().playbackTime = t
            completion(WireFormat.success(["ok": true, "playbackTime": t]))
        } else {
            completion(WireFormat.success(["available": false]))
        }
    }

    @available(macOS 12, *)
    private func queueSnapshot(completion: @escaping @Sendable ([String: Any]) -> Void) {
        if #available(macOS 14, *) {
            let q = playerV14().queue
            let entries = q.entries.map { e -> [String: Any] in
                ["id": e.id, "title": e.title]
            }
            completion(WireFormat.success(["entries": entries, "count": entries.count]))
        } else {
            completion(WireFormat.success(["available": false]))
        }
    }

    @available(macOS 12, *)
    private func setRepeat(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        if #available(macOS 14, *) {
            let mode = (action["mode"] as? String) ?? "off"
            let p = playerV14()
            switch mode {
            case "off": p.state.repeatMode = MusicPlayer.RepeatMode.none
            case "one": p.state.repeatMode = .one
            case "all": p.state.repeatMode = .all
            default: break
            }
            completion(WireFormat.success(["repeatMode": mode]))
        } else {
            completion(WireFormat.success(["available": false]))
        }
    }

    @available(macOS 12, *)
    private func setShuffle(_ action: [String: Any], completion: @escaping @Sendable ([String: Any]) -> Void) {
        if #available(macOS 14, *) {
            let mode = (action["mode"] as? String) ?? "off"
            let p = playerV14()
            switch mode {
            case "off":   p.state.shuffleMode = .off
            case "songs": p.state.shuffleMode = .songs
            default: break
            }
            completion(WireFormat.success(["shuffleMode": mode]))
        } else {
            completion(WireFormat.success(["available": false]))
        }
    }

    @available(macOS 12, *)
    private func nowPlaying(completion: @escaping @Sendable ([String: Any]) -> Void) {
        if #available(macOS 14, *) {
            let p = playerV14()
            var resp: [String: Any] = [
                "status": String(describing: p.state.playbackStatus),
                "playbackRate": p.state.playbackRate,
                "playbackTime": p.playbackTime,
                "repeatMode": String(describing: p.state.repeatMode),
                "shuffleMode": String(describing: p.state.shuffleMode),
                "queueLength": p.queue.entries.count,
            ]
            if let entry = p.queue.currentEntry {
                resp["currentEntry"] = ["id": entry.id, "title": entry.title]
            }
            resp["note"] = "ApplicationMusicPlayer plays inside the bridge process; macOS Music.app state requires Apple Events via interceptor macos intent dispatch --bundle com.apple.Music."
            completion(WireFormat.success(resp))
        } else {
            completion(WireFormat.success(["available": false, "note": "macOS 14+ required for ApplicationMusicPlayer"]))
        }
    }
}
