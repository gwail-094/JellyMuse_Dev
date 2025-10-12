// LyricsParsing.swift (Corrected)
import Foundation

public func parsePreservingBlanks(lyrics: String) -> [LyricLine] {
    var out: [LyricLine] = []
    var lastTime: TimeInterval = 0
    var nonTimedCounter = 0

    let lines = lyrics
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
        .components(separatedBy: "\n")

    for var line in lines {
        while line.last == "\u{000D}" { line.removeLast() }

        var times: [TimeInterval] = []
        var cursor = line[...]
        var consumed = 0

        while let tok = leadingBracketToken(from: cursor) {
            if isMetadataToken(tok) {
                times = []; consumed = 0
                line = "" // ignore whole metadata line
                break
            }
            if let t = parseTimeToken(tok) {
                times.append(t)
                cursor = cursor.dropFirst(tok.count)
                consumed += tok.count
            } else { break }
        }

        if consumed > 0, consumed <= line.count {
            let dropIdx = line.index(line.startIndex, offsetBy: consumed)
            line = String(line[dropIdx...])
        }

        // <<< CHANGE APPLIED HERE
        let cleanText = stripLeadingWeirdSpaces(stripDuetMarkers(line))

        if times.isEmpty {
            if cleanText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                nonTimedCounter += 1
                let t = lastTime + 0.0005 * Double(nonTimedCounter)
                out.append(LyricLine(time: t, text: cleanText))
            } else {
                nonTimedCounter += 1
                let t = lastTime + 0.0005 * Double(nonTimedCounter)
                out.append(LyricLine(time: t, text: cleanText))
                lastTime = t
            }
        } else {
            nonTimedCounter = 0
            for t in times {
                out.append(LyricLine(time: t, text: cleanText))
                if t > lastTime { lastTime = t }
            }
        }
    }

    out.sort { a, b in
        if a.time == b.time { return a.id.uuidString < b.id.uuidString }
        return a.time < b.time
    }
    return out
}

// ---- helpers ----
fileprivate func leadingBracketToken(from slice: Substring) -> String? {
    guard slice.first == "[", let close = slice.firstIndex(of: "]") else { return nil }
    return String(slice[slice.startIndex...close])
}

fileprivate func isMetadataToken(_ token: String) -> Bool {
    guard token.first == "[", token.last == "]" else { return false }
    return token.contains(":") && parseTimeToken(token) == nil
}

fileprivate func parseTimeToken(_ token: String) -> TimeInterval? {
    guard token.first == "[", token.last == "]" else { return nil }
    let inner = token.dropFirst().dropLast()
    let parts = inner.split(separator: ":")
    guard parts.count == 2, let m = Int(parts[0]) else { return nil }

    let secPart = parts[1]
    let secSplit = secPart.split(separator: ".", omittingEmptySubsequences: false)
    guard let s = Int(secSplit[0]), (0...59).contains(s) else { return nil }

    var frac: Double = 0
    if secSplit.count == 2, (1...3).contains(secSplit[1].count), let f = Int(secSplit[1]) {
        frac = Double(f) / pow(10.0, Double(secSplit[1].count))
    } else if secSplit.count > 2 {
        return nil
    }
    return Double(m * 60 + s) + frac
}

fileprivate func stripDuetMarkers(_ raw: String) -> String {
    let t = raw.trimmingCharacters(in: .whitespaces)
    if t.hasPrefix("{"), t.hasSuffix("}"), t.count >= 2 {
        return String(t.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
    }
    if t.hasPrefix("R:") {
        return String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces)
    }
    if t.hasPrefix("{r}") {
        return String(t.dropFirst(3)).trimmingCharacters(in: .whitespaces)
    }
    return raw
}

// compatibility
public func parseLRC(lyrics: String) -> [LyricLine] {
    parsePreservingBlanks(lyrics: lyrics)
}

// <<< NEW UTILITY FUNCTION ADDED HERE
// Strips ANY weird leading whitespace/invisible/bidi markers.
@inline(__always)
public func stripLeadingWeirdSpaces(_ s: String) -> String {
    var scalars = s.unicodeScalars
    func isNasty(_ u: UnicodeScalar) -> Bool {
        if CharacterSet.whitespacesAndNewlines.contains(u) { return true }      // space, tab, \n, \r
        switch u.value {
        case 0x00A0, 0x2000...0x200A, 0x2007, 0x202F, 0x205F, 0x3000: return true // NBSP + Unicode spaces
        case 0x200B, 0x200C, 0x200D, 0x2060: return true                          // zero-width, word joiner
        case 0xFEFF: return true                                                  // BOM
        case 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E,              // bidi markers
             0x2066, 0x2067, 0x2068, 0x2069: return true
        default: return false
        }
    }
    while let f = scalars.first, isNasty(f) { scalars.removeFirst() }
    return String(scalars)
}
