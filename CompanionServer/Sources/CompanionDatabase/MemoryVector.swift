import Foundation

/// Formats an embedding as a pgvector text literal (e.g. `"[0.1,0.2,0.3]"`) for use in raw SQL
/// with an explicit `::vector` cast — PostgresNIO has no native bind type for `vector` columns.
public enum MemoryVector {
  /// Matches OpenAI's `text-embedding-3-small` output size — see `MemoryRepository.migrate()`.
  public static let dimensions = 1536

  public static func encode(_ embedding: [Float]) -> String {
    let components = embedding.map { String(format: "%.8f", $0) }
    return "[\(components.joined(separator: ","))]"
  }
}
