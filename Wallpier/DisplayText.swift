import Foundation

/// Display-only cleanup for text a source reported (titles, creator names, credits). Stored references keep the
/// source's raw text; this runs each time the text is shown, so references saved by older builds read correctly
/// without a migration. Pure, local and dependency-free: there is no HTML renderer here, only text.
enum DisplayText {
    static let defaultLimit = 200

    /// In order: decode named and numeric entities (malformed ones stay literal), remove tag-like spans as text,
    /// strip control and bidi-override characters, normalize to NFC, collapse whitespace, cap the length with an ellipsis.
    /// Returns an empty string when nothing displayable remains; callers choose the fallback.
    static func clean(_ raw: String?, limit: Int = defaultLimit) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        var text = decodeEntities(raw)
        text = removeTags(text)
        text = stripUnsafeScalars(text)
        text = text.precomposedStringWithCanonicalMapping
        text = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if text.count > limit {
            text = String(text.prefix(max(1, limit - 1))).trimmingCharacters(in: .whitespaces) + "…"
        }
        return text
    }

    static func title(_ raw: String?) -> String {
        let cleaned = clean(raw)
        return cleaned.isEmpty ? "Untitled" : cleaned
    }

    static func creator(_ raw: String?) -> String {
        let cleaned = clean(raw)
        return cleaned.isEmpty ? "Unattributed" : cleaned
    }

    // MARK: Entities

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "ndash": "–", "mdash": "—", "hellip": "…", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
        "copy": "©", "reg": "®", "deg": "°", "middot": "·", "bull": "•", "times": "×",
        "agrave": "à", "aacute": "á", "acirc": "â", "atilde": "ã", "auml": "ä", "aring": "å", "aelig": "æ", "ccedil": "ç",
        "egrave": "è", "eacute": "é", "ecirc": "ê", "euml": "ë", "igrave": "ì", "iacute": "í", "icirc": "î", "iuml": "ï",
        "ntilde": "ñ", "ograve": "ò", "oacute": "ó", "ocirc": "ô", "otilde": "õ", "ouml": "ö", "oslash": "ø",
        "ugrave": "ù", "uacute": "ú", "ucirc": "û", "uuml": "ü", "yacute": "ý", "szlig": "ß",
        "Agrave": "À", "Aacute": "Á", "Acirc": "Â", "Auml": "Ä", "Aring": "Å", "Ccedil": "Ç", "Egrave": "È", "Eacute": "É",
        "Ecirc": "Ê", "Iacute": "Í", "Ntilde": "Ñ", "Oacute": "Ó", "Ouml": "Ö", "Uacute": "Ú", "Uuml": "Ü"
    ]

    /// One pass: `&amp;lt;` becomes the literal text `&lt;`, never `<`.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            guard character == "&", let semicolon = text[index...].prefix(34).firstIndex(of: ";") else {
                result.append(character)
                index = text.index(after: index)
                continue
            }
            let body = text[text.index(after: index)..<semicolon]
            if let decoded = decode(String(body)) {
                result.append(decoded)
                index = text.index(after: semicolon)
            } else {
                result.append(character)
                index = text.index(after: index)
            }
        }
        return result
    }

    private static func decode(_ body: String) -> String? {
        guard !body.isEmpty else { return nil }
        if body.hasPrefix("#") {
            let digits = body.dropFirst()
            let value: UInt32?
            if let first = digits.first, first == "x" || first == "X" {
                let hex = digits.dropFirst()
                value = hex.isEmpty || hex.count > 6 || !hex.allSatisfy({ $0.isHexDigit }) ? nil : UInt32(hex, radix: 16)
            } else {
                value = digits.isEmpty || digits.count > 7 || !digits.allSatisfy({ $0.isASCII && $0.isNumber }) ? nil : UInt32(digits, radix: 10)
            }
            guard let value, let scalar = Unicode.Scalar(value) else { return nil }
            return String(Character(scalar))
        }
        return named[body]
    }

    // MARK: Tags

    private static let blockTags: Set<String> = ["br", "p", "div", "li", "ul", "ol", "tr", "td", "th", "table", "hr", "blockquote",
                                                  "section", "article", "h1", "h2", "h3", "h4", "h5", "h6", "dd", "dt", "dl"]
    private static let inlineTags: Set<String> = ["a", "b", "i", "u", "s", "em", "strong", "span", "font", "small", "big", "sub", "sup",
                                                   "code", "cite", "abbr", "tt", "pre", "center", "img", "script", "style", "mark", "del", "ins"]

    /// Removes tag-like spans as text. A closing tag (`</…`, even cut short at the end), a comment or declaration, or an
    /// opening tag with a recognizable name is removed up to the first `>` outside a quoted attribute value; an unterminated
    /// one is dropped to the end. Block-level tags leave a space so the text around them stays apart. A `<` that doesn't start
    /// one of these (“1 < 2”, “<3”) is prose and stays.
    private static func removeTags(_ text: String) -> String {
        guard text.contains("<") else { return text }
        var current = text
        // Removal can join fragments into a new tag, so repeat a bounded number of times.
        for _ in 0..<4 {
            let stripped = stripTagsOnce(current)
            if stripped == current { break }
            current = stripped
        }
        return current
    }

    private static func stripTagsOnce(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        func isLetter(_ scalar: Unicode.Scalar) -> Bool { (65...90).contains(scalar.value) || (97...122).contains(scalar.value) }
        func isDigit(_ scalar: Unicode.Scalar) -> Bool { (48...57).contains(scalar.value) }
        var output = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            guard scalar == "<", index + 1 < scalars.count else { output.append(scalar); index += 1; continue }
            let next = scalars[index + 1]
            let closing = next == "/", declaration = next == "!" || next == "?"
            let nameStart = closing ? index + 2 : index + 1
            if closing, nameStart >= scalars.count { break }                       // a closing tag cut off right after “</”
            guard closing || declaration || isLetter(next) else { output.append(scalar); index += 1; continue }
            guard declaration || isLetter(scalars[nameStart]) else { output.append(scalar); index += 1; continue }
            var nameEnd = nameStart
            var name = ""
            while !declaration, nameEnd < scalars.count, isLetter(scalars[nameEnd]) || isDigit(scalars[nameEnd]) {
                name.unicodeScalars.append(scalars[nameEnd]); nameEnd += 1
            }
            name = name.lowercased()
            if !closing, !declaration {
                // An opening tag must be a known name followed by a space, “/”, “>” or the end.
                let delimited = nameEnd >= scalars.count || scalars[nameEnd] == ">" || scalars[nameEnd] == "/" || scalars[nameEnd].properties.isWhitespace
                guard delimited, blockTags.contains(name) || inlineTags.contains(name) else { output.append(scalar); index += 1; continue }
            }
            var cursor = declaration ? index + 2 : nameEnd
            var quote: Unicode.Scalar?
            var previous: Unicode.Scalar = " "
            while cursor < scalars.count {
                let c = scalars[cursor]
                if let open = quote { if c == open { quote = nil } }
                else if (c == "\"" || c == "'"), previous == "=" { quote = c }
                else if c == ">" { break }
                if !c.properties.isWhitespace { previous = c }
                cursor += 1
            }
            if blockTags.contains(name) { output.append(" ") }
            index = cursor + 1                                                       // past “>”, or past the end if unterminated
        }
        return String(output)
    }

    // MARK: Control and bidi characters

    private static func isUnsafe(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09, 0x0A, 0x0D, 0x0B, 0x0C, 0x85, 0x2028, 0x2029: return false   // whitespace; collapsed afterwards
        case 0x00...0x1F, 0x7F...0x9F: return true
        // Zero-width joiner and non-joiner (U+200D, U+200C) are kept: scripts and emoji sequences need them.
        case 0x200B, 0x200E, 0x200F, 0x202A...0x202E, 0x2060...0x2064, 0x2066...0x206F, 0x061C, 0xFEFF, 0xFFF9...0xFFFB: return true
        default: return false
        }
    }

    private static func stripUnsafeScalars(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where !isUnsafe(scalar) { scalars.append(scalar) }
        return String(scalars)
    }
}
