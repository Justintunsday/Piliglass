import Foundation
import PiliHTTPBodyCodec
import Testing

private struct BodyGolden: Decodable {
  struct Record: Decodable {
    let name: String
    let input: String
    let headers: [String: [String]]
    let decoded: String?
    let utf16: [UInt16]?
    let error: Bool?
  }
  let records: [Record]
}
private struct UTF8Golden: Decodable {
  struct Record: Decodable { let bytes: [UInt8]; let utf16: [UInt16] }
  let records: [Record]
}
private struct CodecCheckFailure: Error { let message: String }

@Suite("Actual Dart body pipeline")
struct BodyCodecTests {
  private func goldenURL(_ name: String) throws -> URL {
    guard let directory = ProcessInfo.processInfo.environment["PILIGLASS_BODY_GOLDEN_DIRECTORY"] else {
      throw CodecCheckFailure(message: "Actual Dart golden directory is required")
    }
    return URL(fileURLWithPath: directory).appendingPathComponent(name)
  }

  @Test func actualRequestCompressionAndDioDecoder() throws {
    let golden = try JSONDecoder().decode(BodyGolden.self,
      from: Data(contentsOf: goldenURL("dart-body-golden.json")))
    #expect(golden.records.count == 25)
    for record in golden.records {
      guard let input = Data(base64Encoded: record.input) else { throw CodecCheckFailure(message: "Invalid input") }
      if record.error == true {
        do {
          _ = try PiliHTTPBodyDecoder.decode(body: input, headers: record.headers, maximumOutputBytes: 200_000)
          throw CodecCheckFailure(message: "\(record.name): Dart failed but native returned bytes")
        } catch PiliHTTPBodyDecodeFailure.malformedCompression { }
      } else {
        guard let encoded = record.decoded, let expected = Data(base64Encoded: encoded),
              let utf16 = record.utf16 else { throw CodecCheckFailure(message: "Incomplete actual Dart output") }
        let actual = try PiliHTTPBodyDecoder.decode(body: input, headers: record.headers, maximumOutputBytes: 200_000)
        guard actual == expected else { throw CodecCheckFailure(message: "\(record.name): decoded bytes differ") }
        guard Array(PiliHTTPBodyDecoder.utf8AllowMalformed(actual).utf16) == utf16 else {
          throw CodecCheckFailure(message: "\(record.name): actual Dio UTF8 units differ")
        }
      }
    }
    print("\(golden.records.count) actual Dart compressed-body cases passed")
  }

  @Test func actualDartUTF8MalformedCorpus() throws {
    let golden = try JSONDecoder().decode(UTF8Golden.self,
      from: Data(contentsOf: goldenURL("dart-utf8-golden.json")))
    #expect(golden.records.count == 67_854)
    for (index, record) in golden.records.enumerated() {
      guard Array(PiliHTTPBodyDecoder.utf8AllowMalformed(Data(record.bytes)).utf16) == record.utf16 else {
        throw CodecCheckFailure(message: "UTF8 vector \(index) differs from actual Dart")
      }
    }
    print("\(golden.records.count) actual Dart UTF8 cases passed")
  }

  @Test func boundedExpansionAndRawBytes() throws {
    let compressed = Data(base64Encoded: "W5+GgV8iLB4LBLL8AgA=")!
    #expect(throws: PiliHTTPBodyDecodeFailure.outputLimit) {
      try PiliHTTPBodyDecoder.decode(body: compressed, headers: ["content-encoding": ["br"]], maximumOutputBytes: 99_999)
    }
    let exact = try PiliHTTPBodyDecoder.decode(body: compressed, headers: ["content-encoding": ["br"]],
                                             maximumOutputBytes: 100_000)
    #expect(exact == Data(repeating: 97, count: 100_000))
    #expect(throws: PiliHTTPBodyDecodeFailure.outputLimit) {
      try PiliHTTPBodyDecoder.decode(body: Data([1]), headers: [:], maximumOutputBytes: 0)
    }
    #expect(try PiliHTTPBodyDecoder.decode(body: Data(), headers: [:], maximumOutputBytes: 0).isEmpty)
    #expect(throws: PiliHTTPBodyDecodeFailure.invalidBudget) {
      try PiliHTTPBodyDecoder.decode(body: Data(), headers: [:], maximumOutputBytes: -1)
    }
    #expect(try PiliHTTPBodyDecoder.decode(body: Data(base64Encoded: "Ow==")!,
      headers: ["content-encoding": ["br"]], maximumOutputBytes: 0).isEmpty)
  }

  @Test func independentConcurrentDecoders() async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0..<16 {
        group.addTask {
          let input = Data(base64Encoded: "W5+GgV8iLB4LBLL8AgA=")!
          let result = try PiliHTTPBodyDecoder.decode(body: input, headers: ["content-encoding": ["br"]],
                                                     maximumOutputBytes: 100_000)
          guard result.count == 100_000 && result.allSatisfy({ $0 == 97 }) else {
            throw CodecCheckFailure(message: "Concurrent Brotli state leaked")
          }
        }
      }
      try await group.waitForAll()
    }
  }
}
