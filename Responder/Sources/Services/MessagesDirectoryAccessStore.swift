import Foundation

enum MessagesDirectoryAccessStore {
    private static let key = "messages_directory_access"

    static func load() -> MessagesDirectoryAccess? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(MessagesDirectoryAccess.self, from: data)
    }

    @discardableResult
    static func save(directoryURL: URL) throws -> MessagesDirectoryAccess {
        let bookmarkData = try directoryURL.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let access = MessagesDirectoryAccess(directoryPath: directoryURL.path, bookmarkData: bookmarkData)
        try save(access)
        return access
    }

    static func save(_ access: MessagesDirectoryAccess) throws {
        let data = try JSONEncoder().encode(access)
        UserDefaults.standard.set(data, forKey: key)
        UserDefaults.standard.synchronize()
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.synchronize()
    }
}
