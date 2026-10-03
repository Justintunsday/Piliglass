import CoreFoundation
import Foundation

/// An owned codec snapshot that can cross actor and thread boundaries.
indirect enum PiliBridgeValue: Sendable, Equatable {
  case null
  case bool(Bool)
  case integer(Int64)
  case double(Double)
  case string(String)
  case array([PiliBridgeValue])
  case dictionary([String: PiliBridgeValue])

  /// Copies Foundation containers on the callback's current thread.
  nonisolated init(codecValue: Any?) throws {
    guard let codecValue, !(codecValue is NSNull) else {
      self = .null
      return
    }

    // NSNumber's bridging casts also accept numeric 0/1 as Bool. Test the
    // underlying CF type first, then preserve its integer or floating type.
    if let number = codecValue as? NSNumber {
      if CFGetTypeID(number) == CFBooleanGetTypeID() {
        self = .bool(number.boolValue)
        return
      }
      switch String(cString: number.objCType) {
      case "c", "s", "i", "l", "q":
        self = .integer(number.int64Value)
      case "C", "S", "I", "L", "Q":
        let value = number.uint64Value
        guard value <= UInt64(Int64.max) else {
          throw PiliBridgeInvocationError.invalidValue
        }
        self = .integer(Int64(value))
      case "f", "d":
        self = .double(number.doubleValue)
      default:
        throw PiliBridgeInvocationError.invalidValue
      }
      return
    }

    if let string = codecValue as? String {
      self = .string(String(decoding: string.utf8, as: UTF8.self))
      return
    }
    if let array = codecValue as? NSArray {
      self = .array(try array.map { try PiliBridgeValue(codecValue: $0) })
      return
    }
    if let dictionary = codecValue as? NSDictionary {
      var snapshot: [String: PiliBridgeValue] = [:]
      snapshot.reserveCapacity(dictionary.count)
      for (key, value) in dictionary {
        // Match piliDictionary: entries with non-string keys are ignored.
        guard let key = key as? String else { continue }
        let copiedKey = String(decoding: key.utf8, as: UTF8.self)
        snapshot[copiedKey] = try PiliBridgeValue(codecValue: value)
      }
      self = .dictionary(snapshot)
      return
    }
    throw PiliBridgeInvocationError.invalidValue
  }

  /// Builds fresh codec containers only where the transport sends them.
  nonisolated var codecValue: Any {
    switch self {
    case .null:
      return NSNull()
    case .bool(let value):
      return NSNumber(value: value)
    case .integer(let value):
      return NSNumber(value: value)
    case .double(let value):
      return NSNumber(value: value)
    case .string(let value):
      return value
    case .array(let values):
      return values.map { $0.codecValue }
    case .dictionary(let values):
      return values.mapValues { $0.codecValue }
    }
  }
}

enum PiliBridgeInvocationError: Error, Sendable, Equatable {
  case unavailable
  case invalidValue
  case platform(code: String, message: String?)
}
