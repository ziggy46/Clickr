import Foundation

/// Trims a release's notes down to what changed.
///
/// The release workflow writes GitHub's generated list of changes first, then this marker,
/// then the install instructions, so everything from the marker on is for people
/// downloading by hand. Releases before 0.3.0 put the install instructions first; for
/// those, the changes start at "## What's Changed".
public enum ReleaseNotes {
    public static let installMarker = "<!-- clickr:install -->"

    public static func whatsNew(in body: String) -> String? {
        var text = body.replacingOccurrences(of: "\r\n", with: "\n")
        if let marker = text.range(of: installMarker) {
            text = String(text[..<marker.lowerBound])
        } else if let changes = text.range(of: "## What's Changed") {
            text = String(text[changes.lowerBound...])
        }

        var lines: [String] = []
        var skippingSection = false
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                // GitHub's "New Contributors" list isn't news to the person updating.
                skippingSection = line.localizedCaseInsensitiveContains("New Contributors")
                if skippingSection { continue }
            }
            if skippingSection || line.hasPrefix("**Full Changelog**") { continue }
            lines.append(withoutAttribution(line))
        }
        let result = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    /// "* Fix a thing by @someone in https://github.com/…/pull/3" reads better without the
    /// trailing "by … in …".
    private static func withoutAttribution(_ line: String) -> String {
        guard line.hasPrefix("* ") || line.hasPrefix("- "),
              let range = line.range(of: #" by @[\w-]+ in https://\S+$"#, options: .regularExpression)
        else { return line }
        return String(line[..<range.lowerBound])
    }
}
