import Foundation

public enum PackagePaths {
  /// Resolves the first existing `.env` near the package root or cwd (Xcode runs from DerivedData).
  public static func dotEnvFile() -> String? {
    for path in candidatePaths() {
      if FileManager.default.fileExists(atPath: path) {
        return path
      }
    }
    return nil
  }

  /// The CompanionServer package root, found by walking up from this source file's
  /// own compile-time path until a directory containing `Package.swift` is found.
  /// Stable regardless of the process's current working directory (Xcode runs
  /// executables from inside DerivedData, not the package root).
  public static func packageRoot() -> String? {
    var sourceDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0..<10 {
      let base = sourceDir.path
      if FileManager.default.fileExists(atPath: "\(base)/Package.swift") {
        return base
      }
      let parent = sourceDir.deletingLastPathComponent()
      if parent.path == sourceDir.path { break }
      sourceDir = parent
    }
    return nil
  }

  /// Resolves `path` against the package root if it's relative; returns it
  /// unchanged if it's already absolute or the package root can't be found.
  public static func resolveRelativeToPackageRoot(_ path: String) -> String {
    guard !path.hasPrefix("/"), let root = packageRoot() else { return path }
    return "\(root)/\(path)"
  }

  private static func candidatePaths() -> [String] {
    var paths: [String] = []
    var seen = Set<String>()

    func append(_ path: String) {
      guard seen.insert(path).inserted else { return }
      paths.append(path)
    }

    var sourceDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0..<10 {
      let base = sourceDir.path
      if FileManager.default.fileExists(atPath: "\(base)/Package.swift") {
        append("\(base)/.env")
      }
      let parent = sourceDir.deletingLastPathComponent()
      if parent.path == sourceDir.path { break }
      sourceDir = parent
    }

    let cwd = FileManager.default.currentDirectoryPath
    append("\(cwd)/.env")
    append("\(cwd)/CompanionServer/.env")

    var cwdDir = URL(fileURLWithPath: cwd)
    for _ in 0..<10 {
      let base = cwdDir.path
      append("\(base)/.env")
      append("\(base)/CompanionServer/.env")
      let parent = cwdDir.deletingLastPathComponent()
      if parent.path == cwdDir.path { break }
      cwdDir = parent
    }

    return paths
  }
}
