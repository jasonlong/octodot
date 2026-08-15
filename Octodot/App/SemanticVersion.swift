import Foundation

struct SemanticVersion: Comparable, Equatable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ string: String) {
        let stripped = string.hasPrefix("v") ? String(string.dropFirst()) : string
        let parts = stripped.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts.allSatisfy(Self.isCanonicalNumericComponent),
              let major = Int(parts[0]),
              let minor = Int(parts[1]),
              let patch = Int(parts[2]) else {
            return nil
        }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    private static func isCanonicalNumericComponent(_ component: Substring) -> Bool {
        guard !component.isEmpty,
              component.utf8.allSatisfy({ (48...57).contains($0) }) else {
            return false
        }
        return component.count == 1 || component.first != "0"
    }

    var description: String {
        "\(major).\(minor).\(patch)"
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}
