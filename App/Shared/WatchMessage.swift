import Foundation

/// The payloads that cross between the phone and the watch. Both sides encode JSON into a
/// WatchConnectivity dictionary so neither has to know about the other's types.
enum WatchMessage {
    /// Phone → watch, as the application context: the whole of today in one value.
    static let snapshotKey = "snapshot"
    /// Watch → phone, as user info: a drink tapped on the wrist.
    static let drinkKey = "drink"
    /// Watch → phone, when it wakes and wants the current numbers.
    static let requestKey = "request"
    /// Watch → phone, as user info: lines from the watch's diagnostic log, which can only
    /// be read once they are in the phone's session log.
    static let logKey = "log"

    static func encode<T: Encodable>(_ value: T, forKey key: String) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(value) else { return [:] }
        return [key: data]
    }

    static func decode<T: Decodable>(_ type: T.Type, from payload: [String: Any], key: String) -> T? {
        guard let data = payload[key] as? Data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
