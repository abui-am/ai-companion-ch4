import Foundation

public enum DatabaseError: Error, CustomStringConvertible, Sendable {
  case invalidURL(String)
  case pingFailed

  public var description: String {
    switch self {
    case .invalidURL(let url):
      "Invalid DATABASE_URL: \(url)"
    case .pingFailed:
      "Postgres ping query did not return 1"
    }
  }
}
