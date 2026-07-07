import Foundation
import PostgresNIO

public struct DatabaseSettings: Sendable {
  public let host: String
  public let port: Int
  public let username: String
  public let password: String
  public let database: String

  public init(urlString: String) throws {
    guard let url = URL(string: urlString) else {
      throw DatabaseError.invalidURL(urlString)
    }
    guard let scheme = url.scheme, scheme == "postgres" || scheme == "postgresql" else {
      throw DatabaseError.invalidURL(urlString)
    }
    guard let host = url.host, !host.isEmpty else {
      throw DatabaseError.invalidURL(urlString)
    }
    guard let username = url.user, !username.isEmpty else {
      throw DatabaseError.invalidURL(urlString)
    }

    let database = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard !database.isEmpty else {
      throw DatabaseError.invalidURL(urlString)
    }

    self.host = host
    self.port = url.port ?? 5432
    self.username = username
    self.password = url.password ?? ""
    self.database = database
  }

  public var postgresConfiguration: PostgresClient.Configuration {
    PostgresClient.Configuration(
      host: host,
      port: port,
      username: username,
      password: password,
      database: database,
      tls: .disable
    )
  }
}
