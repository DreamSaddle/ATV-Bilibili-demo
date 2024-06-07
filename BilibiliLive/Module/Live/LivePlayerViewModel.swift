//
//  LiveInfoViewModel.swift
//  BilibiliLive
//
//  Created by yicheng on 2024/5/13.
//

import Alamofire
import SwiftyJSON

enum LiveError: String, LocalizedError {
    case noLiving
    case noPlaybackUrl
    case fetchApiFail

    var errorDescription: String? {
        rawValue
    }
}

class LivePlayerViewModel {
    init(roomID: Int) {
        self.roomID = roomID
    }

    deinit {
        danMuProvider?.stop()
    }

    var onShootDanmu: ((DanmakuTextCellModel) -> Void)?
    var onPlayUrlStr: ((String) -> Void)?
    var onError: ((String) -> Void)?

    func start() {
        Task {
            do {
                try await refreshRoomsID()
                try await initPlayer()
                await initDanmu()
            } catch let err {
                await MainActor.run {
                    onError?(String(describing: err))
                }
            }
        }
    }

    func playerDidFailToPlay() {
        retryCount += 1
        Task {
            do {
                playInfos = Array(playInfos.dropFirst())
                if playInfos.isEmpty {
                    try await initPlayer()
                    return
                } else {
                    try await playFirstInfo()
                }
            } catch let err {
                await MainActor.run {
                    onError?(err.localizedDescription)
                }
            }
        }
    }

    func debugInfo() -> String {
        return "\(allPlayInfos.first?.formate ?? "") \(allPlayInfos.first?.current_qn ?? 0) retry:\(retryCount)"
    }

    func fetchDespInfo() async -> WebRequest.LiveRoomInfo? {
        return try? await WebRequest.requestLiveBaseInfo(roomID: roomID)
    }

    // Private
    private var allPlayInfos = [LivePlayUrlInfo]()
    private var playInfos = [LivePlayUrlInfo]()
    private var roomID: Int
    private var danMuProvider: LiveDanMuProvider?
    private var retryCount = 0

    private func refreshRoomsID() async throws {
        let info = try await WebRequest.requestLiveRoomInit(roomID: roomID)
        if info.live_status != 1 {
            throw LiveError.noLiving
        }
        roomID = info.room_id
    }

    private func initPlayer() async throws {
        allPlayInfos = []

        let streams = try await WebRequest.requestLiveStreams(roomID: roomID)

        for stream in streams {
            for content in stream.format {
                let formate = content.formatName
                let codecs = content.codec
                for codec in codecs {
                    let qn = codec.currentQn
                    let baseUrl = codec.baseurl
                    for url_info in codec.urlInfo {
                        let host = url_info.host
                        let extra = url_info.extra
                        let url = "\(host)\(baseUrl)\(extra)"
                        let playInfo = LivePlayUrlInfo(formate: formate, url: url, current_qn: qn)
                        allPlayInfos.append(playInfo)
                    }
                }
            }
        }

        allPlayInfos.sort { a, b in
            return a.current_qn ?? 0 > b.current_qn ?? 0
        }

        allPlayInfos.sort { a, b in
            return a.formate == "fmp4"
        }

        Logger.debug("all info arry:\(playInfos)")
        playInfos = allPlayInfos
        try await playFirstInfo()
    }

    func playFirstInfo() async throws {
        if let info = playInfos.first {
            Logger.debug("play =>", playInfos)
            await MainActor.run {
                onPlayUrlStr?(info.url)
            }
        } else {
            throw LiveError.noPlaybackUrl
        }
    }

    private func initDanmu() async {
        danMuProvider = LiveDanMuProvider(roomID: roomID)
        danMuProvider?.onDanmu = {
            [weak self] string in
            let model = DanmakuTextCellModel(str: string)
            DispatchQueue.main.async { [weak self] in
                self?.onShootDanmu?(model)
            }
        }
        danMuProvider?.onSC = {
            [weak self] string in
            let model = DanmakuTextCellModel(str: string)
            model.type = .top
            model.displayTime = 60
            DispatchQueue.main.async { [weak self] in
                self?.onShootDanmu?(model)
            }
        }
        try? await danMuProvider?.start()
    }
}

struct LivePlayUrlInfo {
    let formate: String?
    let url: String
    let current_qn: Int?
}

extension WebRequest.EndPoint {
    static let liveRoomInfo = "https://api.live.bilibili.com/room/v1/Room/get_info"
    static let liveRoomStream = "https://api.live.bilibili.com/xlive/web-room/v2/index/getRoomPlayInfo"
    static let liveRoomInit = "https://api.live.bilibili.com/room/v1/Room/room_init"
}

extension WebRequest {
    struct LiveRoomInfo: Codable {
        let description: String
        let parent_area_name: String
        let title: String
        let tags: String?
        let area_name: String
        let hot_words: [String]?
    }

    static func requestLiveBaseInfo(roomID: Int) async throws -> LiveRoomInfo {
        return try await request(url: EndPoint.liveRoomInfo, parameters: ["room_id": roomID])
    }

    struct LiveRoomInit: Codable {
        var live_status: Int
        var room_id: Int
    }

    static func requestLiveRoomInit(roomID: Int) async throws -> LiveRoomInit {
        return try await request(url: EndPoint.liveRoomInfo, parameters: ["id": roomID])
    }

    static func requestLiveStreams(roomID: Int) async throws -> [LiveStream] {
        struct LiveRoomStreamInfo: Codable {
            let playurl_info: PlayUrlInfo

            struct PlayUrlInfo: Codable {
                let playurl: PlayUrl
            }

            struct PlayUrl: Codable {
                let cid: Int
                let stream: [LiveStream]
            }
        }
        let info: LiveRoomStreamInfo = try await request(url: EndPoint.liveRoomStream,
                                                         parameters: ["room_id": roomID,
                                                                      "protocol": "1",
                                                                      "format": "0,1,2",
                                                                      "codec": "0,1",
                                                                      "qn": "10000",
                                                                      "platform": "web",
                                                                      "ptype": "8",
                                                                      "dolby": "5",
                                                                      "panorama": 1])
        return info.playurl_info.playurl.stream
    }
}

struct LiveStream: Codable {
    let format: [Format]
    let protocol_name: String

    struct Format: Codable {
        let formatName: String
        let codec: [Codec]
        let masterurl: String

        enum CodingKeys: String, CodingKey {
            case formatName = "format_name"
            case codec
            case masterurl = "master_url"
        }

        struct Codec: Codable {
            let urlInfo: [URLInfo]
            let codecName: String
            let currentQn: Int
            let baseurl: String

            enum CodingKeys: String, CodingKey {
                case urlInfo = "url_info"
                case codecName = "codec_name"
                case currentQn = "current_qn"
                case baseurl = "base_url"
            }

            struct URLInfo: Codable {
                let host: String
                let extra: String
            }
        }
    }
}
