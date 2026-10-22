import Foundation

/// The complete lines touched by a paste, with enough surrounding text to keep
/// an older identical line from hiding an edit to the pasted one.
struct PasteBaseline {
    private struct Line {
        let text: String
        let range: NSRange
    }

    private let text: String
    private let lines: [Line]
    private let protectedLines: ClosedRange<Int>?
    private static let maxAlignmentCells = 2_000_000
    private static let infinity = Int.max / 4

    /// Detect edits before B becomes the baseline. Missing or ambiguous content
    /// is not evidence of an edit; leave those cases to the whole-value fallback.
    static func settlementWasEdited(beforeText: String, insertionStart: Int?, insertionLength: Int = 0,
                                    afterText: String, pastedText: String) -> Bool {
        let before = beforeText as NSString
        let pasteLength = (pastedText as NSString).length
        guard pasteLength > 0, insertionLength >= 0 else { return false }
        let start = insertionStart ?? inferredSettlementInsertion(before: beforeText, after: afterText, pasted: pastedText)
        guard let start, start >= 0, start <= before.length,
              insertionLength <= before.length - start else { return false }
        let expected = before.replacingCharacters(in: NSRange(location: start, length: insertionLength), with: pastedText)
        if expected == afterText { return false }
        let expectedLines = splitLines(expected)
        let current = splitLines(afterText)
        guard let region = lineRange(containing: NSRange(location: start, length: pasteLength), in: expectedLines),
              canAlign(expectedLines.count, current.count) else { return false }
        if preservedCost(expectedLines, region: region, current: current) != nil { return false }

        let expectedString = expected as NSString
        let first = expectedLines[region.lowerBound]
        let last = expectedLines[region.upperBound]
        let prefix = expectedString.substring(with: NSRange(location: first.range.location,
                                                            length: start - first.range.location))
        let suffixStart = start + pasteLength
        let contentsEnd = last.range.location + (last.text as NSString).length
        let suffix = suffixStart < contentsEnd ? expectedString.substring(with: NSRange(location: suffixStart,
                                                                                       length: contentsEnd - suffixStart)) : ""
        var candidates: [ClosedRange<Int>] = []
        if !prefix.isEmpty || !suffix.isEmpty {
            for firstIndex in current.indices where prefix.isEmpty || current[firstIndex].text.hasPrefix(prefix) {
                for lastIndex in firstIndex..<current.count where suffix.isEmpty || current[lastIndex].text.hasSuffix(suffix) {
                    candidates.append(firstIndex...lastIndex)
                    guard candidates.count <= 128 else { return false }
                }
            }
        } else {
            // Without surrounding text, only a surviving original paste can
            // identify the row; a completely rewritten row is unlocatable.
            let string = afterText as NSString
            var offset = 0
            while offset < string.length {
                let found = string.range(of: pastedText, options: [], range: NSRange(location: offset, length: string.length - offset))
                if found.location == NSNotFound { break }
                if let candidate = lineRange(containing: found, in: current), !candidates.contains(candidate) {
                    candidates.append(candidate)
                    guard candidates.count <= 128 else { return false }
                }
                offset = found.location + 1
            }
        }

        let target = Array(expectedLines[region]).map(\.text)
        var bestCost = infinity
        var best: ClosedRange<Int>?
        var ambiguous = false
        for candidate in candidates {
            // Any plausible unchanged target keeps this a localization problem,
            // rather than proof that an edit occurred during settlement.
            if Array(current[candidate]).map(\.text) == target { return false }
            guard let prefixCost = distance(Array(expectedLines[..<region.lowerBound]), Array(current[..<candidate.lowerBound])),
                  let suffixCost = distance(Array(expectedLines[(region.upperBound + 1)...]), Array(current[(candidate.upperBound + 1)...])) else { return false }
            let cost = prefixCost + suffixCost
            if cost < bestCost {
                bestCost = cost
                best = candidate
                ambiguous = false
            } else if cost == bestCost, best != candidate {
                ambiguous = true
            }
        }
        return best != nil && !ambiguous
    }

    private static func inferredSettlementInsertion(before: String, after: String, pasted: String) -> Int? {
        let original = splitLines(before)
        let current = splitLines(after)
        let string = after as NSString
        var offset = 0
        var locations = Set<Int>()
        var occurrences = 0
        while offset < string.length {
            let found = string.range(of: pasted, options: [], range: NSRange(location: offset, length: string.length - offset))
            if found.location == NSNotFound { break }
            occurrences += 1
            guard occurrences <= 128, let region = lineRange(containing: found, in: current) else { return nil }
            let first = current[region.lowerBound]
            let last = current[region.upperBound]
            let prefix = string.substring(with: NSRange(location: first.range.location, length: found.location - first.range.location))
            let contentsEnd = last.range.location + (last.text as NSString).length
            let suffix = NSMaxRange(found) < contentsEnd ? string.substring(with: NSRange(location: NSMaxRange(found), length: contentsEnd - NSMaxRange(found))) : ""
            for line in original {
                let text = line.text as NSString
                let prefixLength = (prefix as NSString).length
                if line.text.hasPrefix(prefix), prefixLength <= text.length,
                   suffix.hasSuffix(text.substring(from: prefixLength)) {
                    locations.insert(line.range.location + prefixLength)
                }
                let suffixLength = (suffix as NSString).length
                if line.text.hasSuffix(suffix), suffixLength <= text.length,
                   prefix.hasPrefix(text.substring(to: text.length - suffixLength)) {
                    locations.insert(line.range.location + text.length - suffixLength)
                }
            }
            if before.isEmpty { locations.insert(0) }
            if locations.count > 1 { return nil }
            offset = found.location + 1
        }
        return locations.count == 1 ? locations.first : nil
    }

    init(beforeText: String?, insertionStart: Int?, insertionLength: Int = 0,
         afterText: String, pastedText: String) {
        text = afterText
        lines = Self.splitLines(afterText)
        let after = afterText as NSString
        let pasteLength = (pastedText as NSString).length
        guard pasteLength > 0 else { protectedLines = nil; return }

        if let beforeText, let start = insertionStart,
           start >= 0, insertionLength >= 0 {
            let before = beforeText as NSString
            guard start <= before.length, insertionLength <= before.length - start else {
                protectedLines = nil
                return
            }
            // The old absolute offset can point into refreshed history in B.
            // First paste into A, then align that known target's complete lines.
            let expected = before.replacingCharacters(in: NSRange(location: start, length: insertionLength),
                                                      with: pastedText)
            let expectedLines = Self.splitLines(expected)
            let expectedRegion = Self.lineRange(containing: NSRange(location: start, length: pasteLength),
                                                in: expectedLines)
            if expected == afterText {
                protectedLines = expectedRegion
            } else if let expectedRegion {
                protectedLines = Self.mapRegion(expectedLines, region: expectedRegion, to: lines)
            } else {
                protectedLines = nil
            }
            return
        }

        if beforeText == nil, let start = insertionStart,
           start >= 0, insertionLength >= 0, start <= after.length,
           pasteLength <= after.length - start,
           after.substring(with: NSRange(location: start, length: pasteLength)) == pastedText {
            protectedLines = Self.lineRange(containing: NSRange(location: start, length: pasteLength), in: lines)
        } else if let beforeText {
            let located = Self.inferPaste(before: beforeText, after: afterText,
                                          pasted: pastedText, lines: lines)
            if let located {
                protectedLines = Self.lineRange(containing: located, in: lines)
            } else {
                protectedLines = nil
            }
        } else {
            protectedLines = nil
        }
    }

    func matches(_ currentText: String) -> Bool {
        if currentText == text { return true }
        guard let protectedLines else { return false }
        let current = Self.splitLines(currentText)
        return Self.preservedCost(lines, region: protectedLines, current: current) != nil
    }

    private static func preservedCost(_ originalLines: [Line], region: ClosedRange<Int>,
                                      current: [Line]) -> Int? {
        guard canAlign(originalLines.count, current.count) else { return nil }

        // Track both safe and unsafe minimum-edit alignments. If an equally good
        // alignment edits the protected lines, their identity is ambiguous: fail
        // closed instead of finding an unchanged copy in the scrollback.
        var safe = Array(repeating: Self.infinity, count: current.count + 1)
        var unsafe = safe
        safe[0] = 0
        for column in 1..<(current.count + 1) { safe[column] = column }
        for (row, original) in originalLines.enumerated() {
            var nextSafe = Array(repeating: Self.infinity, count: current.count + 1)
            var nextUnsafe = nextSafe
            let protected = region.contains(row)
            Self.advance(safe[0] + 1, unsafe[0] + 1, dangerous: protected,
                         safe: &nextSafe[0], unsafe: &nextUnsafe[0])
            for (column, candidate) in current.enumerated() {
                let equal = original.text == candidate.text
                // Replacing an external row costs a delete plus an insert. A
                // cheap substitution must not obscure a unique surviving row.
                Self.advance(safe[column] + (equal ? 0 : 2), unsafe[column] + (equal ? 0 : 2),
                             dangerous: protected && !equal,
                             safe: &nextSafe[column + 1], unsafe: &nextUnsafe[column + 1])
                Self.advance(safe[column + 1] + 1, unsafe[column + 1] + 1,
                             dangerous: protected,
                             safe: &nextSafe[column + 1], unsafe: &nextUnsafe[column + 1])
                // An insertion between two protected lines changes the region.
                let inside = row + 1 > region.lowerBound && row + 1 <= region.upperBound
                Self.advance(nextSafe[column] + 1, nextUnsafe[column] + 1, dangerous: inside,
                             safe: &nextSafe[column + 1], unsafe: &nextUnsafe[column + 1])
            }
            safe = nextSafe
            unsafe = nextUnsafe
        }
        return safe[current.count] < unsafe[current.count] ? safe[current.count] : nil
    }

    private static func mapRegion(_ original: [Line], region: ClosedRange<Int>,
                                  to current: [Line]) -> ClosedRange<Int>? {
        guard let cost = preservedCost(original, region: region, current: current) else { return nil }
        let target = Array(original[region]).map(\.text)
        var result: ClosedRange<Int>?
        for start in matchingStarts(target, in: current) {
            let end = start + target.count
            guard let prefixCost = distance(Array(original[..<region.lowerBound]), Array(current[..<start])),
                  let suffixCost = distance(Array(original[(region.upperBound + 1)...]), Array(current[end...])),
                  prefixCost + suffixCost == cost else { continue }
            if result != nil { return nil }
            result = start...(end - 1)
        }
        return result
    }

    private static func advance(_ safeCost: Int, _ unsafeCost: Int, dangerous: Bool,
                                safe: inout Int, unsafe: inout Int) {
        if dangerous {
            unsafe = min(unsafe, safeCost, unsafeCost)
        } else {
            safe = min(safe, safeCost)
            unsafe = min(unsafe, unsafeCost)
        }
    }

    private static func splitLines(_ text: String) -> [Line] {
        let string = text as NSString
        var result: [Line] = []
        var offset = 0
        while offset < string.length {
            var start = 0, end = 0, contentsEnd = 0
            string.getLineStart(&start, end: &end, contentsEnd: &contentsEnd,
                                for: NSRange(location: offset, length: 0))
            // A line terminator separates rows; appending an outside row must
            // not look like an edit to the preceding row's actual text.
            result.append(Line(text: string.substring(with: NSRange(location: start, length: contentsEnd - start)),
                               range: NSRange(location: start, length: end - start)))
            offset = end
        }
        return result
    }

    private static func lineRange(containing range: NSRange, in lines: [Line]) -> ClosedRange<Int>? {
        let indices = lines.indices.filter {
            lines[$0].range.location < NSMaxRange(range) && NSMaxRange(lines[$0].range) > range.location
        }
        guard let first = indices.first, let last = indices.last else { return nil }
        return first...last
    }

    private static func canAlign(_ first: Int, _ second: Int) -> Bool {
        first + 1 <= maxAlignmentCells / (second + 1)
    }

    private static func distance(_ first: [Line], _ second: [Line]) -> Int? {
        guard canAlign(first.count, second.count) else { return nil }
        var previous = Array(0...second.count)
        for (row, original) in first.enumerated() {
            var next = Array(repeating: 0, count: second.count + 1)
            next[0] = row + 1
            for (column, candidate) in second.enumerated() {
                next[column + 1] = min(previous[column] + (original.text == candidate.text ? 0 : 2),
                                       previous[column + 1] + 1, next[column] + 1)
            }
            previous = next
        }
        return previous[second.count]
    }

    private static func matchingStarts(_ target: [String], in lines: [Line]) -> [Int] {
        guard !target.isEmpty, target.count <= lines.count else { return [] }
        return (0...(lines.count - target.count)).filter { start in
            target.indices.allSatisfy { target[$0] == lines[start + $0].text }
        }
    }

    private static func inferPaste(before: String, after: String, pasted: String,
                                   lines: [Line]) -> NSRange? {
        let original = splitLines(before)
        guard let unchangedCost = distance(original, lines), unchangedCost > 0 else { return nil }
        let string = after as NSString
        var search = NSRange(location: 0, length: string.length)
        var bestCost = unchangedCost
        var best: NSRange?
        var possibleRegion: ClosedRange<Int>?
        var candidates = 0
        while search.length > 0 {
            let found = string.range(of: pasted, options: [], range: search)
            if found.location == NSNotFound { break }
            candidates += 1
            // A screen full of repeated fragments offers no useful localization.
            guard candidates <= 128,
                  let removedCost = distance(original, splitLines(string.replacingCharacters(in: found, with: ""))),
                  let region = lineRange(containing: found, in: lines) else { return nil }
            let target = Array(lines[region]).map(\.text)
            // A second newly containing line can be a selection replacement,
            // even if removing its paste does not recover A. Do not let the
            // cheaper pure-insertion candidate in a refreshed row win instead.
            let newOccurrence = matchingStarts(target, in: lines).count > matchingStarts(target, in: original).count
            if newOccurrence {
                if let possibleRegion, possibleRegion != region { return nil }
                possibleRegion = region
            } else {
                let next = found.location + 1
                search = NSRange(location: next, length: string.length - next)
                continue
            }
            if removedCost < bestCost {
                bestCost = removedCost
                best = found
            }
            let next = found.location + 1
            search = NSRange(location: next, length: string.length - next)
        }
        return best
    }
}
