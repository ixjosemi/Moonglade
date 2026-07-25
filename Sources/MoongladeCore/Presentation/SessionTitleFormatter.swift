import Foundation

/// Derives a row title from the live Ghostty tab title. Agents write far
/// better titles than a directory name — five sessions in one repository
/// are indistinguishable by directory — but they decorate them with status
/// emoji, spinners, separators and ellipses that are noise in a row.
///
/// The row's single-line Text does the real width-aware tail truncation;
/// the character cap here only guards against pathological titles so a
/// runaway tab string never bloats layout or accessibility labels.
public enum SessionTitleFormatter {
    public static let maximumTitleLength = 120

    public static func rowTitle(tabTitle: String?, fallback: String) -> String {
        guard let tabTitle, let cleanedTitle = clean(tabTitle) else {
            return truncate(fallback, to: maximumTitleLength)
        }
        return truncate(cleanedTitle, to: maximumTitleLength)
    }

    /// Truncation counts user-perceived characters and spends the last slot
    /// on the ellipsis, so results never exceed the limit.
    public static func truncate(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let prefix = String(text.prefix(limit - 1))
            .trimmingCharacters(in: .whitespaces)
        return prefix + "…"
    }

    /// Nil means the title carried no real text — decoration only — and the
    /// caller should fall back to the directory name.
    private static func clean(_ title: String) -> String? {
        var text = title.replacingOccurrences(of: "…", with: "")
        text = text.replacingOccurrences(
            of: #"\.{3,}"#,
            with: "",
            options: .regularExpression
        )
        // Everything before the first letter or digit is status decoration:
        // "🟢 | title", "✳ title", "● title".
        guard let firstReadable = text.firstIndex(where: { $0.isLetter || $0.isNumber }) else {
            return nil
        }
        text = String(text[firstReadable...])
        text = text.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        text = text.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }
}
