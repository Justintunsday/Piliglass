import Foundation

struct PiliNativeVideo: Identifiable {
  let id: String
  let sourceID: String
  let aid: Int?
  let bvid: String?
  let title: String
  let cover: String?
  let owner: String
  let viewText: String
  let danmakuText: String
  let durationText: String
  let pubdateText: String

  init(summary: PiliSearchVideoSummary, index: Int) {
    sourceID = summary.sourceID
    id = "\(sourceID)-\(index)"
    aid = summary.aid
    bvid = summary.bvid
    title = summary.title ?? piliLocalized("未命名视频")
    cover = summary.cover
    owner = summary.owner
    viewText = summary.viewText
    danmakuText = summary.danmakuText
    durationText = summary.durationText
    pubdateText = summary.pubdateText
  }

  init(map: [String: Any], index: Int) {
    sourceID = piliString(map["id"]) ?? "video"
    id = "\(sourceID)-\(index)"
    aid = piliOptionalInt(map["aid"])
    bvid = piliString(map["bvid"])
    title = piliString(map["title"]) ?? piliLocalized("未命名视频")
    cover = piliString(map["cover"])
    owner = piliString(map["owner"]) ?? ""
    viewText = piliString(map["viewText"]) ?? ""
    danmakuText = piliString(map["danmakuText"]) ?? ""
    durationText = piliString(map["durationText"]) ?? ""
    pubdateText = piliString(map["pubdateText"]) ?? ""
  }
}
