final class StrictPersistentJsonException implements Exception {
  const StrictPersistentJsonException(this.code);
  final String code;
}

/// Bounded persistent-JSON entry boundary. It rejects duplicate keys (including
/// escaped duplicates), non-integer number tokens, control characters, bad
/// escapes and trailing data before any map becomes visible. Depth, node and
/// code-unit budgets are enforced during the single pass.
abstract final class StrictPersistentJson {
  static Object? parse(
    String source, {
    required int maxCodeUnits,
    required int maxDepth,
    required int maxNodes,
  }) {
    if (source.length > maxCodeUnits) {
      throw const StrictPersistentJsonException('codeUnitLimit');
    }
    final reader = _Reader(source, maxDepth, maxNodes);
    final value = reader.value(0);
    reader.skipWhitespace();
    if (!reader.isAtEnd) {
      throw const StrictPersistentJsonException('trailingData');
    }
    return value;
  }
}

final class _Reader {
  _Reader(this.source, this.maxDepth, this.maxNodes);

  final String source;
  final int maxDepth;
  final int maxNodes;
  int _index = 0;
  int _nodes = 0;

  bool get isAtEnd => _index >= source.length;

  void skipWhitespace() {
    while (!isAtEnd) {
      final unit = source.codeUnitAt(_index);
      if (unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D) {
        _index++;
      } else {
        break;
      }
    }
  }

  Object? value(int depth) {
    if (depth > maxDepth) {
      throw const StrictPersistentJsonException('depthLimit');
    }
    _countNode();
    skipWhitespace();
    if (isAtEnd) {
      throw const StrictPersistentJsonException('unexpectedEnd');
    }
    final unit = source.codeUnitAt(_index);
    switch (unit) {
      case 0x7B:
        return _object(depth);
      case 0x5B:
        return _array(depth);
      case 0x22:
        return _string();
      case 0x74:
        _literal('true');
        return true;
      case 0x66:
        _literal('false');
        return false;
      case 0x6E:
        _literal('null');
        return null;
      default:
        if (unit == 0x2D || (unit >= 0x30 && unit <= 0x39)) {
          return _integer();
        }
        throw const StrictPersistentJsonException('unexpectedValue');
    }
  }

  Map<String, Object?> _object(int depth) {
    _index++;
    final result = <String, Object?>{};
    skipWhitespace();
    if (_take(0x7D)) return result;
    while (true) {
      skipWhitespace();
      _countNode();
      final key = _string();
      if (result.containsKey(key)) {
        throw const StrictPersistentJsonException('duplicateKey');
      }
      skipWhitespace();
      if (!_take(0x3A)) {
        throw const StrictPersistentJsonException('missingColon');
      }
      result[key] = value(depth + 1);
      skipWhitespace();
      if (_take(0x7D)) return result;
      if (!_take(0x2C)) {
        throw const StrictPersistentJsonException('missingComma');
      }
    }
  }

  List<Object?> _array(int depth) {
    _index++;
    final result = <Object?>[];
    skipWhitespace();
    if (_take(0x5D)) return result;
    while (true) {
      result.add(value(depth + 1));
      skipWhitespace();
      if (_take(0x5D)) return result;
      if (!_take(0x2C)) {
        throw const StrictPersistentJsonException('missingComma');
      }
    }
  }

  String _string() {
    if (!_take(0x22)) {
      throw const StrictPersistentJsonException('missingString');
    }
    final buffer = StringBuffer();
    var segment = _index;
    while (!isAtEnd) {
      final unit = source.codeUnitAt(_index);
      if (unit == 0x22) {
        buffer.write(source.substring(segment, _index));
        _index++;
        return buffer.toString();
      }
      if (unit < 0x20) {
        throw const StrictPersistentJsonException('controlCharacter');
      }
      if (unit == 0x5C) {
        buffer.write(source.substring(segment, _index));
        _index++;
        if (isAtEnd) {
          throw const StrictPersistentJsonException('unexpectedEnd');
        }
        final escape = source.codeUnitAt(_index++);
        if (escape == 0x22 || escape == 0x5C || escape == 0x2F) {
          buffer.writeCharCode(escape);
        } else if (escape == 0x62) {
          buffer.writeCharCode(0x08);
        } else if (escape == 0x66) {
          buffer.writeCharCode(0x0C);
        } else if (escape == 0x6E) {
          buffer.writeCharCode(0x0A);
        } else if (escape == 0x72) {
          buffer.writeCharCode(0x0D);
        } else if (escape == 0x74) {
          buffer.writeCharCode(0x09);
        } else if (escape == 0x75) {
          if (_index + 4 > source.length) {
            throw const StrictPersistentJsonException('invalidUnicodeEscape');
          }
          var code = 0;
          for (var i = 0; i < 4; i++) {
            code = code * 16 + _hex(source.codeUnitAt(_index + i));
          }
          _index += 4;
          buffer.writeCharCode(code);
        } else {
          throw const StrictPersistentJsonException('invalidEscape');
        }
        segment = _index;
      } else {
        _index++;
      }
    }
    throw const StrictPersistentJsonException('unterminatedString');
  }

  int _integer() {
    final start = _index;
    if (_take(0x2D) && isAtEnd) {
      throw const StrictPersistentJsonException('invalidNumber');
    }
    if (isAtEnd) {
      throw const StrictPersistentJsonException('invalidNumber');
    }
    final first = source.codeUnitAt(_index);
    if (first == 0x30) {
      _index++;
      if (!isAtEnd && _isDigit(source.codeUnitAt(_index))) {
        throw const StrictPersistentJsonException('invalidNumber');
      }
    } else if (first >= 0x31 && first <= 0x39) {
      _index++;
      while (!isAtEnd && _isDigit(source.codeUnitAt(_index))) {
        _index++;
      }
    } else {
      throw const StrictPersistentJsonException('invalidNumber');
    }
    if (!isAtEnd) {
      final unit = source.codeUnitAt(_index);
      if (unit == 0x2E || unit == 0x65 || unit == 0x45) {
        // Persistent records carry integer tokens only; 1.0 is not 1.
        throw const StrictPersistentJsonException('nonIntegerNumber');
      }
    }
    final value = int.tryParse(source.substring(start, _index));
    if (value == null) {
      throw const StrictPersistentJsonException('invalidNumber');
    }
    return value;
  }

  void _literal(String text) {
    if (_index + text.length > source.length) {
      throw const StrictPersistentJsonException('invalidLiteral');
    }
    for (var i = 0; i < text.length; i++) {
      if (source.codeUnitAt(_index + i) != text.codeUnitAt(i)) {
        throw const StrictPersistentJsonException('invalidLiteral');
      }
    }
    _index += text.length;
  }

  bool _take(int unit) {
    if (!isAtEnd && source.codeUnitAt(_index) == unit) {
      _index++;
      return true;
    }
    return false;
  }

  void _countNode() {
    if (++_nodes > maxNodes) {
      throw const StrictPersistentJsonException('nodeLimit');
    }
  }

  static bool _isDigit(int unit) => unit >= 0x30 && unit <= 0x39;

  static int _hex(int unit) {
    if (unit >= 0x30 && unit <= 0x39) return unit - 0x30;
    if (unit >= 0x41 && unit <= 0x46) return unit - 0x37;
    if (unit >= 0x61 && unit <= 0x66) return unit - 0x57;
    throw const StrictPersistentJsonException('invalidUnicodeEscape');
  }
}
