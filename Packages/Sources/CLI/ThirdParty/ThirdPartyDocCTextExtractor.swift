import Foundation

enum ThirdPartyDocCTextExtractor {
    private enum RenderMode {
        case search
        case display
    }

    private struct ReferenceInfo {
        let title: String
        let url: String?
    }

    private static let excludedSubtrees: Set<String> = [
        "references",
        "declarations",
        "metadata",
        "navigatorindex",
        "downloadnotavailablesummary",
        "symbolkind",
    ]

    private static let narrativeKeys: [String] = [
        "abstract",
        "overview",
        "discussion",
        "primaryContentSections",
        "topicSections",
        "seeAlsoSections",
        "relationshipsSections",
        "chapters",
        "resources",
        "tutorials",
        "content",
        "inlineContent",
        "sections",
        "children",
        "items",
        "steps",
        "identifiers",
        "caption",
        "code",
        "text",
        "tiles",
    ]

    static func searchableContent(from jsonObject: Any) -> String {
        let references = referencesLookup(from: jsonObject)
        var blocks: [String] = []

        if let title = firstString(forKey: "title", in: jsonObject) {
            appendInlineBlock(title, into: &blocks)
        }

        blocks.append(contentsOf: renderBlocks(
            from: jsonObject,
            currentKey: nil,
            references: references,
            mode: .search
        ))

        return finalizeBlocks(blocks)
    }

    static func renderedMarkdown(from jsonObject: Any, pageTitle: String? = nil) -> String {
        let references = referencesLookup(from: jsonObject)
        var blocks: [String] = []

        if let title = pageTitle ?? firstString(forKey: "title", in: jsonObject) {
            blocks.append("# \(normalizeInlineText(title))")
        }

        blocks.append(contentsOf: renderBlocks(
            from: jsonObject,
            currentKey: nil,
            references: references,
            mode: .display
        ))

        return finalizeBlocks(blocks)
    }

    private static func renderBlocks(
        from value: Any,
        currentKey: String?,
        references: [String: ReferenceInfo],
        mode: RenderMode
    ) -> [String] {
        switch value {
        case let dictionary as [String: Any]:
            if let currentKey, excludedSubtrees.contains(currentKey.lowercased()) {
                return []
            }

            if let type = valueForKey("type", in: dictionary) as? String {
                let loweredType = type.lowercased()
                switch loweredType {
                case "paragraph":
                    if let paragraph = renderParagraph(from: dictionary, references: references, mode: mode) {
                        return [paragraph]
                    }
                    return []
                case "heading":
                    let headingSource = valueForKey("text", in: dictionary)
                        ?? valueForKey("inlineContent", in: dictionary)
                    guard let headingSource else {
                        return []
                    }
                    let heading = renderInline(from: headingSource, references: references, mode: mode)
                    guard !heading.isEmpty else {
                        return []
                    }
                    if mode == .display {
                        let level = (valueForKey("level", in: dictionary) as? Int) ?? 2
                        return ["\(String(repeating: "#", count: max(1, min(6, level)))) \(heading)"]
                    }
                    return [heading]
                case "codelisting":
                    return renderCodeListing(from: dictionary)
                case "unorderedlist", "orderedlist":
                    return renderList(
                        from: dictionary,
                        ordered: loweredType == "orderedlist",
                        references: references,
                        mode: mode
                    )
                case "listitem":
                    return renderListItem(
                        from: dictionary,
                        ordered: false,
                        index: nil,
                        references: references,
                        mode: mode
                    )
                case "text", "codevoice", "reference":
                    let inline = renderInline(from: dictionary, references: references, mode: mode)
                    guard !inline.isEmpty else {
                        return []
                    }
                    return [inline]
                default:
                    break
                }
            }

            var blocks: [String] = []
            if mode == .display,
               shouldRenderSectionHeading(for: currentKey),
               let title = valueForKey("title", in: dictionary) as? String {
                let normalized = normalizeInlineText(title)
                if shouldKeep(normalized) {
                    blocks.append("## \(normalized)")
                }
            }
            for key in narrativeKeys {
                guard let nested = valueForKey(key, in: dictionary) else {
                    continue
                }
                blocks.append(contentsOf: renderBlocks(
                    from: nested,
                    currentKey: key.lowercased(),
                    references: references,
                    mode: mode
                ))
            }

            if blocks.isEmpty {
                let fallback = renderInline(from: dictionary, references: references, mode: mode)
                if !fallback.isEmpty {
                    blocks.append(fallback)
                }
            }
            return blocks
        case let array as [Any]:
            if isInlineFragmentArray(array) {
                let inline = renderInline(from: array, references: references, mode: mode)
                return inline.isEmpty ? [] : [inline]
            }

            if mode == .display, isSectionItemArray(currentKey: currentKey, array: array) {
                return renderSectionItems(from: array, references: references)
            }

            var blocks: [String] = []
            for element in array {
                blocks.append(contentsOf: renderBlocks(
                    from: element,
                    currentKey: currentKey,
                    references: references,
                    mode: mode
                ))
            }
            return blocks
        case let string as String:
            guard let currentKey else {
                return []
            }
            if currentKey == "identifiers" || currentKey == "tutorials" {
                let rendered = renderIdentifier(string, references: references, mode: mode)
                guard shouldKeep(rendered) else {
                    return []
                }
                if mode == .display {
                    return ["- \(rendered)"]
                }
                return [rendered]
            }
            guard currentKey == "text" || currentKey == "code" else {
                return []
            }
            let normalized = normalizeInlineText(string)
            guard shouldKeep(normalized) else {
                return []
            }
            return [normalized]
        default:
            return []
        }
    }

    private static func renderParagraph(
        from dictionary: [String: Any],
        references: [String: ReferenceInfo],
        mode: RenderMode
    ) -> String? {
        let source = valueForKey("inlineContent", in: dictionary)
            ?? valueForKey("content", in: dictionary)
            ?? valueForKey("text", in: dictionary)
        guard let source else {
            return nil
        }
        let paragraph = renderInline(from: source, references: references, mode: mode)
        return paragraph.isEmpty ? nil : paragraph
    }

    private static func renderCodeListing(from dictionary: [String: Any]) -> [String] {
        guard let rawCode = valueForKey("code", in: dictionary) as? String else {
            return []
        }
        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            return []
        }
        let syntax = (valueForKey("syntax", in: dictionary) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let language = (syntax?.isEmpty == false ? syntax! : "swift")
        return ["```\(language)\n\(code)\n```"]
    }

    private static func renderInline(
        from value: Any,
        references: [String: ReferenceInfo],
        mode: RenderMode
    ) -> String {
        let fragments = renderInlineFragments(from: value, references: references, mode: mode)
        guard !fragments.isEmpty else {
            return ""
        }
        return cleanInlineSpacing(joinInlineFragments(fragments))
    }

    private static func renderInlineFragments(
        from value: Any,
        references: [String: ReferenceInfo],
        mode: RenderMode
    ) -> [String] {
        switch value {
        case let dictionary as [String: Any]:
            if let type = valueForKey("type", in: dictionary) as? String {
                switch type.lowercased() {
                case "text":
                    if let text = valueForKey("text", in: dictionary) as? String {
                        let normalized = normalizeInlineText(text)
                        return shouldKeep(normalized) ? [normalized] : []
                    }
                    return []
                case "codevoice":
                    let text = (valueForKey("code", in: dictionary) as? String)
                        ?? (valueForKey("text", in: dictionary) as? String)
                    guard let text else {
                        return []
                    }
                    let normalized = normalizeInlineText(text)
                    guard shouldKeep(normalized) else {
                        return []
                    }
                    return ["`\(escapeBackticks(normalized))`"]
                case "reference":
                    let reference = renderReferenceInline(from: dictionary, references: references, mode: mode)
                    return reference.isEmpty ? [] : [reference]
                case "link":
                    let text = (valueForKey("text", in: dictionary) as? String)
                        ?? (valueForKey("title", in: dictionary) as? String)
                    let destination = valueForKey("destination", in: dictionary) as? String
                    if mode == .display, let text, let destination {
                        let normalized = normalizeInlineText(text)
                        return shouldKeep(normalized) ? ["[\(normalized)](\(destination))"] : []
                    }
                    if let text {
                        let normalized = normalizeInlineText(text)
                        return shouldKeep(normalized) ? [normalized] : []
                    }
                    return []
                default:
                    break
                }
            }

            if let inline = valueForKey("inlineContent", in: dictionary) {
                return renderInlineFragments(from: inline, references: references, mode: mode)
            }

            if let text = valueForKey("text", in: dictionary) as? String {
                let normalized = normalizeInlineText(text)
                return shouldKeep(normalized) ? [normalized] : []
            }
            return []
        case let array as [Any]:
            return array.flatMap { renderInlineFragments(from: $0, references: references, mode: mode) }
        case let string as String:
            let normalized = normalizeInlineText(string)
            return shouldKeep(normalized) ? [normalized] : []
        default:
            return []
        }
    }

    private static func renderReferenceInline(
        from dictionary: [String: Any],
        references: [String: ReferenceInfo],
        mode: RenderMode
    ) -> String {
        let literalTitle = (valueForKey("text", in: dictionary) as? String).map(normalizeInlineText)
        let identifier = valueForKey("identifier", in: dictionary) as? String
        let info = identifier.flatMap { references[$0] }
        let fallback = identifier?.split(separator: "/").last.map(String.init)
        let rawTitle = literalTitle ?? info?.title ?? fallback ?? ""
        let normalized = normalizeInlineText(rawTitle)
        guard shouldKeep(normalized) else {
            return ""
        }

        if mode == .display,
           let identifier,
           let destination = info?.url ?? documentationURL(from: identifier) {
            return "[\(normalized)](\(destination))"
        }

        if shouldRenderAsInlineCode(normalized) {
            return "`\(escapeBackticks(normalized))`"
        }
        return normalized
    }

    private static func referencesLookup(from jsonObject: Any) -> [String: ReferenceInfo] {
        guard let root = jsonObject as? [String: Any],
              let references = valueForKey("references", in: root) as? [String: Any] else {
            return [:]
        }

        var infos: [String: ReferenceInfo] = [:]
        infos.reserveCapacity(references.count)

        for (identifier, value) in references {
            guard let reference = value as? [String: Any] else {
                continue
            }

            let fallbackTitle = identifier
                .split(separator: "/")
                .last
                .map(String.init) ?? identifier
            let title = (valueForKey("title", in: reference) as? String) ?? fallbackTitle
            let normalized = normalizeInlineText(title)
            guard shouldKeep(normalized) else {
                continue
            }
            infos[identifier] = ReferenceInfo(
                title: normalized,
                url: resolveReferenceURL(from: reference, identifier: identifier)
            )
        }

        return infos
    }

    private static func documentationURL(from identifier: String) -> String? {
        guard identifier.hasPrefix("doc://") else {
            return nil
        }
        let stripped = identifier.replacingOccurrences(of: "doc://", with: "")

        if let range = stripped.range(of: "/documentation/") {
            let path = String(stripped[range.upperBound...])
            return "https://developer.apple.com/documentation/\(path)"
        }
        if let range = stripped.range(of: "/tutorials/") {
            let path = String(stripped[range.upperBound...])
            return "https://developer.apple.com/tutorials/\(path)"
        }
        return nil
    }

    private static func resolveReferenceURL(
        from reference: [String: Any],
        identifier: String
    ) -> String? {
        if let url = valueForKey("url", in: reference) as? String {
            if url.hasPrefix("http://") || url.hasPrefix("https://") {
                return url
            }
            if url.hasPrefix("/") {
                return "https://developer.apple.com\(url)"
            }
            return url
        }
        return documentationURL(from: identifier)
    }

    private static func renderIdentifier(
        _ identifier: String,
        references: [String: ReferenceInfo],
        mode: RenderMode
    ) -> String {
        let normalizedIdentifier = normalizeInlineText(identifier)
        if let info = references[normalizedIdentifier] {
            if mode == .display, let url = info.url ?? documentationURL(from: normalizedIdentifier) {
                return "[\(info.title)](\(url))"
            }
            return info.title
        }

        if mode == .display, let url = documentationURL(from: normalizedIdentifier) {
            let fallback = normalizedIdentifier.split(separator: "/").last.map(String.init) ?? normalizedIdentifier
            return "[\(fallback)](\(url))"
        }

        return normalizedIdentifier
    }

    private static func renderList(
        from dictionary: [String: Any],
        ordered: Bool,
        references: [String: ReferenceInfo],
        mode: RenderMode
    ) -> [String] {
        guard let items = valueForKey("items", in: dictionary) as? [Any] else {
            return []
        }

        var rendered: [String] = []
        for (index, item) in items.enumerated() {
            if let itemDict = item as? [String: Any] {
                rendered.append(contentsOf: renderListItem(
                    from: itemDict,
                    ordered: ordered,
                    index: index + 1,
                    references: references,
                    mode: mode
                ))
            } else if let string = item as? String {
                let normalized = normalizeInlineText(string)
                guard shouldKeep(normalized) else { continue }
                if mode == .display {
                    rendered.append(ordered ? "\(index + 1). \(normalized)" : "- \(normalized)")
                } else {
                    rendered.append(normalized)
                }
            }
        }
        return rendered
    }

    private static func renderListItem(
        from dictionary: [String: Any],
        ordered: Bool,
        index: Int?,
        references: [String: ReferenceInfo],
        mode: RenderMode
    ) -> [String] {
        let source = valueForKey("content", in: dictionary)
            ?? valueForKey("inlineContent", in: dictionary)
            ?? valueForKey("text", in: dictionary)

        guard let source else {
            return []
        }

        var itemText = renderInline(from: source, references: references, mode: mode)
        if itemText.isEmpty {
            let nested = renderBlocks(from: source, currentKey: nil, references: references, mode: mode)
            itemText = nested.joined(separator: " ")
        }
        let normalized = cleanInlineSpacing(itemText)
        guard shouldKeep(normalized) else {
            return []
        }

        if mode == .display {
            let prefix: String
            if ordered, let index {
                prefix = "\(index). "
            } else {
                prefix = "- "
            }
            return [prefix + normalized]
        }
        return [normalized]
    }

    private static func isSectionItemArray(currentKey: String?, array: [Any]) -> Bool {
        guard let currentKey else { return false }
        let keys: Set<String> = ["chapters", "resources", "sections", "topicsections", "seealsosections", "tiles"]
        guard keys.contains(currentKey.lowercased()) else { return false }
        return array.allSatisfy { $0 is [String: Any] }
    }

    private static func renderSectionItems(
        from array: [Any],
        references: [String: ReferenceInfo]
    ) -> [String] {
        var blocks: [String] = []

        for value in array {
            guard let dictionary = value as? [String: Any] else { continue }
            let headingSource = (valueForKey("title", in: dictionary) as? String)
                ?? (valueForKey("name", in: dictionary) as? String)
            if let headingSource {
                let normalizedTitle = normalizeInlineText(headingSource)
                if shouldKeep(normalizedTitle) {
                    blocks.append("### \(normalizedTitle)")
                }
            }

            if let abstract = valueForKey("abstract", in: dictionary) {
                let rendered = renderInline(from: abstract, references: references, mode: .display)
                if shouldKeep(rendered) {
                    blocks.append(rendered)
                }
            }

            if let content = valueForKey("content", in: dictionary) {
                blocks.append(contentsOf: renderBlocks(
                    from: content,
                    currentKey: "content",
                    references: references,
                    mode: .display
                ))
            }

            if let action = valueForKey("action", in: dictionary) as? [String: Any] {
                let actionLabel = (valueForKey("overridingTitle", in: action) as? String)
                    ?? (valueForKey("title", in: action) as? String)
                let normalizedLabel = actionLabel.map(normalizeInlineText)
                if let destination = valueForKey("destination", in: action) as? String,
                   let normalizedLabel,
                   shouldKeep(normalizedLabel) {
                    blocks.append("- [\(normalizedLabel)](\(destination))")
                } else if let identifier = valueForKey("identifier", in: action) as? String {
                    let rendered = renderIdentifier(identifier, references: references, mode: .display)
                    if shouldKeep(rendered) {
                        blocks.append("- \(rendered)")
                    }
                }
            }

            for key in ["identifiers", "tutorials"] {
                if let entries = valueForKey(key, in: dictionary) as? [Any], !entries.isEmpty {
                    for entry in entries {
                        if let string = entry as? String {
                            let rendered = renderIdentifier(string, references: references, mode: .display)
                            if shouldKeep(rendered) {
                                blocks.append("- \(rendered)")
                            }
                        }
                    }
                }
            }

            for key in ["chapters", "resources", "tiles", "items"] {
                guard let nested = valueForKey(key, in: dictionary) else {
                    continue
                }
                blocks.append(contentsOf: renderBlocks(
                    from: nested,
                    currentKey: key,
                    references: references,
                    mode: .display
                ))
            }
        }

        return blocks
    }

    private static func shouldRenderSectionHeading(for key: String?) -> Bool {
        guard let key else { return false }
        let keys: Set<String> = [
            "topicsections",
            "seealsosections",
            "relationshipssections",
            "sections",
            "chapters",
            "resources",
            "tutorials",
        ]
        return keys.contains(key.lowercased())
    }

    private static func valueForKey(_ key: String, in dictionary: [String: Any]) -> Any? {
        if let exact = dictionary[key] {
            return exact
        }
        let lowercasedKey = key.lowercased()
        return dictionary.first(where: { $0.key.lowercased() == lowercasedKey })?.value
    }

    private static func appendInlineBlock(_ value: String?, into blocks: inout [String]) {
        guard let value else {
            return
        }
        let normalized = normalizeInlineText(value)
        guard shouldKeep(normalized) else {
            return
        }
        if blocks.last != normalized {
            blocks.append(normalized)
        }
    }

    private static func finalizeBlocks(_ blocks: [String]) -> String {
        var deduped: [String] = []
        deduped.reserveCapacity(blocks.count)

        for rawBlock in blocks {
            let normalizedBlock: String
            if rawBlock.hasPrefix("```") {
                normalizedBlock = rawBlock
            } else {
                normalizedBlock = cleanInlineSpacing(rawBlock)
            }

            let trimmed = normalizedBlock.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }

            if deduped.last != trimmed {
                deduped.append(trimmed)
            }
        }

        return deduped.joined(separator: "\n\n")
    }

    private static func isInlineFragmentArray(_ array: [Any]) -> Bool {
        guard !array.isEmpty else {
            return false
        }

        return array.allSatisfy { element in
            guard let dictionary = element as? [String: Any],
                  let type = valueForKey("type", in: dictionary) as? String else {
                return false
            }

            switch type.lowercased() {
            case "text", "reference", "codevoice", "emphasis", "strong", "link":
                return true
            default:
                return false
            }
        }
    }

    private static func joinInlineFragments(_ fragments: [String]) -> String {
        var output = ""

        for fragment in fragments {
            let trimmed = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }

            guard !output.isEmpty else {
                output = trimmed
                continue
            }

            if shouldAvoidSpace(before: trimmed) || shouldAvoidSpace(after: output) {
                output += trimmed
            } else {
                output += " " + trimmed
            }
        }

        return output
    }

    private static func shouldAvoidSpace(before fragment: String) -> Bool {
        guard let first = fragment.first else {
            return false
        }
        return ",.;:!?)]}".contains(first)
    }

    private static func shouldAvoidSpace(after output: String) -> Bool {
        guard let last = output.last else {
            return false
        }
        return "([{".contains(last)
    }

    private static func cleanInlineSpacing(_ value: String) -> String {
        var normalized = normalizeInlineText(value)
        normalized = normalized.replacingOccurrences(
            of: #"\s+([,.;:!?])"#,
            with: "$1",
            options: .regularExpression
        )
        normalized = normalized.replacingOccurrences(
            of: #"([(\[{])\s+"#,
            with: "$1",
            options: .regularExpression
        )
        normalized = normalized.replacingOccurrences(
            of: #"\s+([)\]}])"#,
            with: "$1",
            options: .regularExpression
        )
        return normalized
    }

    private static func shouldRenderAsInlineCode(_ value: String) -> Bool {
        value.contains("(")
            || value.contains(")")
            || value.contains(":")
            || value.contains("<")
            || value.contains(">")
            || value.contains("_")
            || value.contains(".")
    }

    private static func escapeBackticks(_ value: String) -> String {
        value.replacingOccurrences(of: "`", with: "\\`")
    }

    private static func shouldKeep(_ value: String) -> Bool {
        guard !value.isEmpty else {
            return false
        }
        if value.hasPrefix("doc://") || value.hasPrefix("s:") {
            return false
        }
        return true
    }

    private static func normalizeInlineText(_ value: String) -> String {
        value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstString(forKey key: String, in value: Any) -> String? {
        switch value {
        case let dictionary as [String: Any]:
            if let direct = dictionary[key] as? String {
                return direct
            }
            for nested in dictionary.values {
                if let found = firstString(forKey: key, in: nested) {
                    return found
                }
            }
        case let array as [Any]:
            for nested in array {
                if let found = firstString(forKey: key, in: nested) {
                    return found
                }
            }
        default:
            break
        }
        return nil
    }
}
