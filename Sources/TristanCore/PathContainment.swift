import Foundation

/// Which path rules apply: POSIX on the Mac and iOS, Win32 on Windows.
package enum PathFlavor: Sendable {
    case posix, windows

    package static var current: PathFlavor {
        #if os(Windows)
        return .windows
        #else
        return .posix
        #endif
    }
}

/// Decides whether a path lies inside a folder. Both paths are expected to be resolved already (`SafePath.real`);
/// this compares them as strings, but by path segments, never by a bare string prefix.
///
/// Windows rules, all failing closed (an unparseable or ambiguous path is never inside anything):
/// - `\` and `/` are the same separator; repeated and trailing separators are ignored.
/// - Drive letters and ASCII letters compare case-insensitively. Non-ASCII text compares exactly, without Unicode
///   normalisation, because NTFS folds case with its own table and never normalises (`Straße` is not `STRASSE`).
/// - `.` and `..` are resolved before comparing; climbing above the drive or share root is rejected.
/// - UNC roots (`\\server\share`) contain only paths on the same server and share; a UNC path is never inside a
///   drive root or the other way round.
/// - `\\?\C:\…`, `\\.\C:\…` and `\\?\UNC\server\share\…` are read as their drive or UNC form. Because Windows does not
///   normalise `\\?\` paths, those must not contain `/` or dot segments. Other device paths are rejected.
/// - Rejected outright: NUL and other control characters, drive-relative (`C:foo`), root-relative (`\foo`) and
///   relative paths, `:` after the drive (alternate data streams), wildcards and `<>"|`, reserved device names
///   (`NUL`, `CON.txt`, `COM1`), and any segment ending in a dot or a space (Win32 strips some of those, NTFS can
///   hold others, so the path is ambiguous).
/// - Out of scope: 8.3 short names (`PROGRA~1`) and junctions. Both must be expanded by the file system
///   (`SafePath.real`) before this check; an unexpanded short name only compares as a different, outside, name.
/// - Known limitation: per-directory case-sensitive NTFS folders (`fsutil file setCaseSensitiveInfo`, WSL) are not
///   detected. Inside such a folder `Proj` and `proj` are different siblings, and the case-insensitive compare here
///   would treat a path under `proj` as inside the root `Proj`.
package enum PathContainment {
    /// How a tool's path argument is read before it is joined to the working folder.
    package enum InputForm: Equatable, Sendable {
        case absolute, relative, rejected
    }

    /// `path` is the root itself or lies below it.
    package static func contains(root: String, path: String, flavor: PathFlavor) -> Bool {
        switch flavor {
        case .posix:
            return path == root || path.hasPrefix(root + "/")
        case .windows:
            guard let r = WindowsPath(root), let p = WindowsPath(path) else { return false }
            return r.isPrefix(of: p)
        }
    }

    /// `path` lies below `root` and is not the root itself.
    package static func isStrictlyInside(root: String, path: String, flavor: PathFlavor) -> Bool {
        switch flavor {
        case .posix:
            return path.hasPrefix(root + "/")
        case .windows:
            guard let r = WindowsPath(root), let p = WindowsPath(path) else { return false }
            return r.isPrefix(of: p) && p.segments.count > r.segments.count
        }
    }

    /// Absolute paths are used as given, relative ones are joined to the working folder, rejected ones are refused.
    /// On Windows `C:\x`, `C:/x` and `\\server\share\x` are absolute; drive-relative `C:x` and root-relative `\x`
    /// (which depend on per-drive state the agent cannot see) are rejected.
    package static func form(of path: String, flavor: PathFlavor) -> InputForm {
        switch flavor {
        case .posix:
            return path.hasPrefix("/") ? .absolute : .relative
        case .windows:
            let scalars = Array(path.unicodeScalars)
            if scalars.contains(where: { $0.value < 0x20 }) { return .rejected }
            func isSep(_ i: Int) -> Bool { i < scalars.count && (scalars[i] == "\\" || scalars[i] == "/") }
            if scalars.count >= 2, scalars[1] == ":" {
                return isASCIILetter(scalars[0]) && isSep(2) ? .absolute : .rejected
            }
            if isSep(0) { return isSep(1) ? .absolute : .rejected }
            return .relative
        }
    }

    fileprivate static func isASCIILetter(_ s: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(s) || ("A"..."Z").contains(s)
    }
}

/// A parsed, normalised absolute Windows path: its root and its segments, ASCII case-folded.
private struct WindowsPath {
    enum Root: Equatable {
        case drive(Unicode.Scalar)
        case unc(server: [UInt32], share: [UInt32])
    }

    let root: Root
    let segments: [[UInt32]]

    func isPrefix(of other: WindowsPath) -> Bool {
        root == other.root && segments.count <= other.segments.count
            && Array(other.segments.prefix(segments.count)) == segments
    }

    private static let reservedNames: Set<String> = {
        var names: Set<String> = ["con", "prn", "aux", "nul", "conin$", "conout$"]
        for n in ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "\u{b9}", "\u{b2}", "\u{b3}"] {
            names.insert("com" + n)
            names.insert("lpt" + n)
        }
        return names
    }()

    private static let forbidden: Set<Unicode.Scalar> = [":", "*", "?", "\"", "<", ">", "|"]

    init?(_ input: String) {
        var scalars = Array(input.unicodeScalars)
        guard !scalars.isEmpty, !scalars.contains(where: { $0.value < 0x20 }) else { return nil }

        // Device and extended prefixes: `\\?\` and `\\.\` (written with backslashes).
        var extended = false
        if scalars.count >= 4, scalars[0] == "\\", scalars[1] == "\\", scalars[2] == "?" || scalars[2] == ".", scalars[3] == "\\" {
            // Windows does not normalise these, so `/` is not a separator and dot segments are literal.
            guard !scalars.contains("/") else { return nil }
            extended = true
            let rest = Array(scalars[4...])
            if rest.count >= 4, String(String.UnicodeScalarView(rest[0..<4])).uppercased() == "UNC\\" {
                scalars = ["\\", "\\"] + rest[4...]
            } else if rest.count >= 3, PathContainment.isASCIILetter(rest[0]), rest[1] == ":", rest[2] == "\\" {
                scalars = rest
            } else {
                return nil   // volume GUIDs, raw devices, pipes: never inside a working folder
            }
        }
        scalars = scalars.map { $0 == "/" ? "\\" : $0 }

        // Foundation on Windows may report a drive path as `/C:/x`.
        if !extended, scalars.count >= 4, scalars[0] == "\\", PathContainment.isASCIILetter(scalars[1]),
           scalars[2] == ":", scalars[3] == "\\" {
            scalars.removeFirst()
        }

        let parts = scalars.split(separator: "\\", omittingEmptySubsequences: false).map(Array.init)
        let root: Root
        let rest: ArraySlice<[Unicode.Scalar]>
        if scalars.count >= 3, PathContainment.isASCIILetter(scalars[0]), scalars[1] == ":", scalars[2] == "\\" {
            let letter = scalars[0].properties.lowercaseMapping.unicodeScalars.first ?? scalars[0]
            root = .drive(letter)
            rest = parts.dropFirst()
        } else if scalars.count >= 2, scalars[0] == "\\", scalars[1] == "\\" {
            // parts: "", "", server, share, ...
            guard parts.count >= 4,
                  let server = Self.validSegment(parts[2]), let share = Self.validSegment(parts[3]) else { return nil }
            root = .unc(server: server, share: share)
            rest = parts.dropFirst(4)
        } else {
            return nil   // relative, drive-relative or root-relative
        }

        var segments: [[UInt32]] = []
        for part in rest where !part.isEmpty {
            if part == ["."] {
                if extended { return nil }
                continue
            }
            if part == [".", "."] {
                if extended || segments.isEmpty { return nil }
                segments.removeLast()
                continue
            }
            guard let segment = Self.validSegment(part) else { return nil }
            segments.append(segment)
        }
        self.root = root
        self.segments = segments
    }

    /// A file or folder name, ASCII case-folded, or nil if Windows would read it ambiguously.
    private static func validSegment(_ part: [Unicode.Scalar]) -> [UInt32]? {
        guard let last = part.last, last != ".", last != " " else { return nil }
        guard !part.contains(where: forbidden.contains) else { return nil }
        let folded = part.map { s -> UInt32 in
            ("A"..."Z").contains(s) ? s.value + 32 : s.value
        }
        // Reserved device names apply to the part before the first dot, ignoring trailing spaces.
        let base = String(String.UnicodeScalarView(part.prefix { $0 != "." }))
            .lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " "))
        guard !reservedNames.contains(base) else { return nil }
        return folded
    }
}
