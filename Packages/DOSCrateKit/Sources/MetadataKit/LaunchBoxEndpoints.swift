import Foundation

public enum LaunchBoxEndpoints {
    public static let metadataZipURL = URL(string: "https://gamesdb.launchbox-app.com/Metadata.zip")!
    public static let imageBaseURL = URL(string: "https://images.launchbox-app.com/")!

    public static func imageURL(for fileName: String) -> URL {
        let trimmed = fileName.hasPrefix("/") ? String(fileName.dropFirst()) : fileName
        return URL(string: trimmed, relativeTo: imageBaseURL)!.absoluteURL
    }
}
