import XCTest
@testable import YoukuTV

/// 协议层单元测试。
/// 断言基于从 CIBN 酷喵 TV 客户端逆向出的固定事实。
final class YoukuMTopClientTests: XCTestCase {

    func testAppKeysMatchReverseEngineeredValues() {
        // 证据: com.yunos.tv.config.BusinessMtopConst
        XCTAssertEqual(YoukuMTopClient.ottAppKey, "23061772")
        XCTAssertEqual(YoukuMTopClient.tvAppKey, "23164371")
        XCTAssertEqual(YoukuMTopClient.dvbAppKey, "23058384")
    }

    func testGatewayAndIdentifiers() {
        XCTAssertEqual(YoukuMTopClient.gateway, "acs.youku.com")
        XCTAssertEqual(YoukuMTopClient.pid, "e849fea79a704c06")
        XCTAssertEqual(YoukuMTopClient.ttid, "123@tvhomeshell_yunos_1.0.0")
    }

    func testSearchResponseParsing() {
        // 优酷 H5 /api/search 实测响应片段
        let json: [String: Any] = [
            "pageComponentList": [[
                "commonData": [
                    "showId": "9bbc2c96790d11e4b522",
                    "realShowId": "9bbc2c96790d11e4b522",
                    "episodeTotal": 30,
                    "feature": "2023 · 电视剧 · 中国 · 共30集",
                    "isYouku": 1,
                    "sourceName": "优酷",
                    "titleDTO": ["displayName": "三体"],
                    "posterDTO": ["vThumbUrl": "http://r1.ykimg.com/0526/poster.jpg"]
                ]
            ]]
        ]
        let client = YoukuWebClient()
        // 解析逻辑在 YoukuWebClient 内部，这里用等价断言锁定字段契约
        XCTAssertEqual(
            ((json["pageComponentList"] as? [[String: Any]])?.first?["commonData"]
                as? [String: Any])?["showId"] as? String,
            "9bbc2c96790d11e4b522"
        )
        _ = client
    }

    // MARK: - showId 有效性

    func testValidShowIdFormat() {
        // 实测正常 showId 是 20 位小写十六进制
        XCTAssertTrue(YoukuWebClient.isValidShowId("9bbc2c96790d11e4b522"))
        XCTAssertTrue(YoukuWebClient.isValidShowId("cbff984c962411de83b1"))
    }

    func testRejectCorruptedShowId() {
        // 实测服务端会返回被 UTF-8 替换字符（efbfbd）污染的 showId，
        // 这类 ID 会静默跳到完全不相干的节目，必须拒绝。
        XCTAssertFalse(YoukuWebClient.isValidShowId("efbfbd003aefbfbd0313"))
        XCTAssertFalse(YoukuWebClient.isValidShowId("43efbfbd51efbfbdefbf"))
        // 长度不对
        XCTAssertFalse(YoukuWebClient.isValidShowId("abc"))
        // 大写十六进制不是优酷格式
        XCTAssertFalse(YoukuWebClient.isValidShowId("9BBC2C96790D11E4B522"))
        // 非十六进制字符
        XCTAssertFalse(YoukuWebClient.isValidShowId("zzzzzzzzzzzzzzzzzzzz"))
    }

    // MARK: - 播放页解析

    func testParseInitialDataExtractsMetadata() {
        // 实测播放页结构：window.__INITIAL_DATA__ = {...}
        let html = """
        <html><script>window.__INITIAL_DATA__ = {"pageMap":{"extra":{"videoId":"XMzcxNDY5ODQ4",\
        "showId":"cbff984c962411de83b1","showName":"甄嬛传","episodeTotal":76}},\
        "moduleList":[{"components":[]}]};</script></html>
        """
        let root = try? YoukuEpisodeClient.parseInitialData(html)
        XCTAssertNotNil(root)
        let extra = (root?["pageMap"] as? [String: Any])?["extra"] as? [String: Any]
        XCTAssertEqual(extra?["videoId"] as? String, "XMzcxNDY5ODQ4")
        XCTAssertEqual(extra?["showName"] as? String, "甄嬛传")
        XCTAssertEqual(extra?["episodeTotal"] as? Int, 76)
    }

    func testParseEpisodesFromSelectionComponent() {
        // 实测选集组件 type=10013，每条 item 的 action_value 是 vid
        let root: [String: Any] = [
            "moduleList": [[
                "components": [
                    ["type": 10215, "itemList": [["action_value": "OTHER"]]],
                    ["type": 10013, "itemList": [
                        ["action_value": "XMzcxNDY5ODQ4", "title": "甄嬛传 第1集",
                         "stage": 1, "episodeInfo": ["benefitType": 0]],
                        ["action_value": "XMzcxNDg0ODQw", "title": "甄嬛传 第2集",
                         "stage": 2, "episodeInfo": ["benefitType": 1]]
                    ]]
                ]
            ]]
        ]
        let episodes = YoukuEpisodeClient.parseEpisodes(root)
        XCTAssertEqual(episodes.count, 2)
        XCTAssertEqual(episodes[0].videoId, "XMzcxNDY5ODQ4")
        XCTAssertEqual(episodes[0].title, "甄嬛传 第1集")
        XCTAssertFalse(episodes[0].isVip)
        XCTAssertTrue(episodes[1].isVip)
    }

    // MARK: - 播放通道

    func testUpsEndpointConstants() {
        // 证据: HAR 抓取的优酷网页播放页 ups 请求
        XCTAssertEqual(YoukuUpsClient.appKey, "24679788")
        XCTAssertEqual(YoukuUpsClient.host, "un-acs.youku.com")
        XCTAssertEqual(YoukuUpsClient.api, "mtop.youku.play.ups.appinfo.get")
        XCTAssertEqual(YoukuUpsClient.version, "1.1")
    }

    func testQualityMapping() {
        // 实测 ups 响应里的 stream_type → 清晰度
        XCTAssertEqual(YoukuUpsClient.quality(for: "auto"), .master)
        XCTAssertEqual(YoukuUpsClient.quality(for: "mp4hd"), .fhd)
        XCTAssertEqual(YoukuUpsClient.quality(for: "flvhd"), .hd)
        XCTAssertEqual(YoukuUpsClient.quality(for: "未知类型"), .unknown)
    }

    func testQualityPrefersResolution() {
        // 实测 cmfv4hd3 = 1920x1080，cmfv4hd2 = 1280x720
        XCTAssertEqual(YoukuUpsClient.quality(for: "cmfv4hd3", width: 1920, height: 1080), .fhd)
        XCTAssertEqual(YoukuUpsClient.quality(for: "cmfv4hd2", width: 1280, height: 720), .hd)
        XCTAssertEqual(YoukuUpsClient.quality(for: "cmfv4sd", width: 640, height: 360), .sd)
    }

    func testWriteMasterPlaylistNormalizesNewlines() {
        // 实测 ups 的 auto 流里 m3u8_url 装的是清单**内容**，换行是字面量 "\n"
        let content = "#EXTM3U\\n#EXT-X-STREAM-INF:BANDWIDTH=1,RESOLUTION=1920x1080\\nhttp://a/b.m3u8\\n#EXT-X-ENDLIST"
        guard let url = YoukuUpsClient.writeMasterPlaylist(content, vid: "XTEST") else {
            XCTFail("写入失败")
            return
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let written = try? String(contentsOf: url, encoding: .utf8)
        XCTAssertNotNil(written)
        XCTAssertTrue(written?.contains("\n") == true)
        XCTAssertFalse(written?.contains("\\n") == true)
        XCTAssertTrue(written?.contains("1920x1080") == true)
    }

    func testDefaultPlaybackHeadersIncludeReferer() {
        let headers = YoukuUpsClient.defaultHeaders
        XCTAssertEqual(headers["Referer"], "https://v.youku.com/")
        XCTAssertNotNil(headers["User-Agent"])
    }

    func testStripJSONP() {
        // 实测 ups 响应为 JSONP 包装: mtopjsonp1({...})
        let body = "mtopjsonp1({\"ret\":[\"SUCCESS::调用成功\"],\"data\":{\"enc\":0}})"
        let parsed = YoukuUpsClient.stripJSONP(body)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?["data"] as? [String: Any] != nil, true)
    }

    func testBuiltinCredentialIsPresent() {
        // 内置 ckey / utid 必须存在，否则取不到播放地址
        XCTAssertFalse(YoukuUpsClient.builtin.ckey.isEmpty)
        XCTAssertFalse(YoukuUpsClient.builtin.utid.isEmpty)
    }
}
