import Foundation
#if canImport(Security)
import Security
#endif

/// API 키 보관 (Keychain). 테스트·CLI 환경에서는 메모리 저장소로 대체할 수 있다.
public protocol SecretStore: Sendable {
    func get(_ key: String) -> String?
    func set(_ key: String, _ value: String) throws
    func delete(_ key: String)
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private var dict: [String: String] = [:]
    private let lock = NSLock()
    public init() {}
    public func get(_ key: String) -> String? { lock.withLock { dict[key] } }
    public func set(_ key: String, _ value: String) throws { lock.withLock { dict[key] = value } }
    public func delete(_ key: String) { lock.withLock { _ = dict.removeValue(forKey: key) } }
}

#if canImport(Security)
public struct KeychainStore: SecretStore {
    public let service: String
    public init(service: String = "app.tunemate.apikeys") { self.service = service }

    public func get(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let d = item as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    public func set(_ key: String, _ value: String) throws {
        delete(key)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key,
                                kSecValueData as String: Data(value.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        let s = SecItemAdd(q as CFDictionary, nil)
        guard s == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(s)) }
    }
    public func delete(_ key: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
    }
}
#endif

/// 공급자별 키 읽기·공급자 인스턴스 만들기.
public struct ProviderFactory: Sendable {
    public var secrets: SecretStore
    public var transport: HTTPTransport
    public init(secrets: SecretStore, transport: HTTPTransport = URLSessionTransport()) { self.secrets = secrets; self.transport = transport }

    public static func keyName(_ p: AIProviderKind) -> String { "apikey.\(p.rawValue)" }
    public func hasKey(_ p: AIProviderKind) -> Bool { !(secrets.get(Self.keyName(p)) ?? "").isEmpty }

    public func make(_ p: AIProviderKind) throws -> any LLMProvider {
        guard let key = secrets.get(Self.keyName(p)), !key.isEmpty else { throw LLMError.missingAPIKey(p) }
        switch p {
        case .anthropic: return AnthropicProvider(apiKey: key, transport: transport)
        case .openai: return OpenAIProvider(apiKey: key, transport: transport)
        case .gemini: return GeminiProvider(apiKey: key, transport: transport)
        }
    }
}
