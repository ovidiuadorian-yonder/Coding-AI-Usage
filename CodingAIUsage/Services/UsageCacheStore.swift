import Foundation

protocol UsageCacheStoring {
    func load(id: String) -> ServiceUsage?
    func save(_ usage: ServiceUsage)
}

final class UserDefaultsUsageCacheStore: UsageCacheStoring {
    private let userDefaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let keyPrefix = "usage.cache."

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func load(id: String) -> ServiceUsage? {
        guard let data = userDefaults.data(forKey: cacheKey(for: id)) else {
            return nil
        }
        return try? decoder.decode(ServiceUsage.self, from: data)
    }

    func save(_ usage: ServiceUsage) {
        guard let data = try? encoder.encode(usage) else {
            return
        }
        userDefaults.set(data, forKey: cacheKey(for: usage.id))
    }

    private func cacheKey(for id: String) -> String {
        keyPrefix + id
    }
}
