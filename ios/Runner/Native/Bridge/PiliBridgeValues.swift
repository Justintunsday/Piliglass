import Foundation

func piliDictionary(_ value: Any?) -> [String: Any] {
  if let dictionary = value as? [String: Any] { return dictionary }
  guard let dictionary = value as? NSDictionary else { return [:] }
  var result: [String: Any] = [:]
  dictionary.forEach { key, value in
    if let key = key as? String { result[key] = value }
  }
  return result
}

func piliString(_ value: Any?) -> String? {
  if value is NSNull || value == nil { return nil }
  if let value = value as? String, !value.isEmpty { return value }
  return nil
}

func piliOptionalInt(_ value: Any?) -> Int? {
  if value is NSNull || value == nil { return nil }
  if let value = value as? NSNumber { return value.intValue }
  if let value = value as? String { return Int(value) }
  return nil
}

func piliInt(_ value: Any?) -> Int {
  piliOptionalInt(value) ?? 0
}

func piliDouble(_ value: Any?) -> Double {
  if let value = value as? NSNumber { return value.doubleValue }
  if let value = value as? String { return Double(value) ?? 0 }
  return 0
}

func piliOptionalDouble(_ value: Any?) -> Double? {
  if value is NSNull || value == nil { return nil }
  if let value = value as? NSNumber { return value.doubleValue }
  if let value = value as? String { return Double(value) }
  return nil
}

func piliBool(_ value: Any?) -> Bool {
  if let value = value as? Bool { return value }
  if let value = value as? NSNumber { return value.boolValue }
  if let value = value as? String { return value == "true" || value == "1" }
  return false
}
