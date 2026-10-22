import CryptoKit
import Engine
import Foundation
import Security

enum ChatGPTOAuth {
    static let issuer = "https://auth.openai.com"
    static let resource = "https://api.openai.com/v1"
    static let scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    struct Attempt: Sendable {
        let state = random(), nonce = random(), verifier = random()
        let redirect: URL
        let clientID: String?
        let hostID: String
        let idTokenHint: String?
        var authorizationURL: URL {
            var url = URLComponents(string: issuer + "/api/accounts/authorize")!
            var items = ["client_id": clientID ?? "dynamic_agent_client", "ext_agent_host_id": hostID,
                         "response_type": "code", "redirect_uri": redirect.absoluteString,
                         "scope": scopes, "resource": resource, "state": state, "nonce": nonce,
                         "code_challenge_method": "S256", "code_challenge": Data(SHA256.hash(data: Data(verifier.utf8))).base64URL]
            if clientID == nil { items["agent_name_hint"] = "wavepod" }
            if let idTokenHint { items["id_token_hint"] = idTokenHint }
            url.queryItems = items.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            return url.url!
        }
        func callback(_ url: URL) throws -> (code: String, client: String) {
            guard url.scheme == redirect.scheme, url.host == "127.0.0.1", url.port == redirect.port,
                  url.path == redirect.path, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { throw invalid() }
            var values: [String: String] = [:]
            for item in items {
                guard values[item.name] == nil, let value = item.value else { throw invalid() }
                values[item.name] = value
            }
            guard values["state"] == state else { throw invalid() }
            if values["error"] != nil { throw EngineError.unavailable("ChatGPT connection was declined. Continue with ChatGPT again to allow plan usage.") }
            guard let code = values["code"], !code.isEmpty,
                  let issued = values["client_id"] ?? clientID, !issued.isEmpty, issued != "dynamic_agent_client",
                  clientID == nil || clientID == issued else { throw invalid() }
            return (code, issued)
        }
    }
    static func invalid() -> EngineError { .unavailable("wavepod could not verify the ChatGPT sign-in. Try again.") }
    static func random() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess)
        return Data(bytes).base64URL
    }
    static func form(_ values: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return Data(values.sorted { $0.key < $1.key }.map {
            $0.key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + $0.value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&").utf8)
    }

    /// A decoded JWT alone is never proof of identity. Verify RS256 with the pinned issuer's JWKS first.
    static func identity(token: String, jwks: Data, client: String, nonce: String, now: Date = .now) throws -> (subject: String, email: String) {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let headerData = Data(base64URL: parts[0]), let payloadData = Data(base64URL: parts[1]),
              let signature = Data(base64URL: parts[2]),
              let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              header["alg"] as? String == "RS256", let kid = header["kid"] as? String,
              let set = try JSONSerialization.jsonObject(with: jwks) as? [String: Any], let keys = set["keys"] as? [[String: Any]],
              let key = keys.first(where: { $0["kid"] as? String == kid && $0["kty"] as? String == "RSA" }),
              let n = key["n"] as? String, let e = key["e"] as? String,
              let modulus = Data(base64URL: n), let exponent = Data(base64URL: e) else { throw invalid() }
        func der(_ tag: UInt8, _ body: Data) -> Data {
            var length = body.count, bytes: [UInt8] = []
            if length < 128 { bytes = [UInt8(length)] }
            else {
                while length > 0 { bytes.insert(UInt8(length & 255), at: 0); length >>= 8 }
                bytes.insert(0x80 | UInt8(bytes.count), at: 0)
            }
            return Data([tag] + bytes) + body
        }
        func integer(_ bytes: Data) -> Data {
            let trimmed = Data(bytes.drop(while: { $0 == 0 }))
            return der(0x02, (trimmed.first.map { $0 >= 128 } == true ? Data([0]) : Data()) + trimmed)
        }
        let keyData = der(0x30, integer(modulus) + integer(exponent))
        guard let publicKey = SecKeyCreateWithData(keyData as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, nil),
              SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256,
                                    Data((parts[0] + "." + parts[1]).utf8) as CFData, signature as CFData, nil),
              let payload = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              payload["iss"] as? String == issuer, payload["nonce"] as? String == nonce,
              let expiry = payload["exp"] as? Double, expiry > now.timeIntervalSince1970,
              let subject = payload["sub"] as? String, !subject.isEmpty else { throw invalid() }
        let audience = (payload["aud"] as? [String]) ?? (payload["aud"] as? String).map { [$0] } ?? []
        guard audience.contains(client), (audience.count == 1 || payload["azp"] as? String == client) else { throw invalid() }
        if let issued = payload["iat"] as? Double, issued > now.timeIntervalSince1970 + 60 { throw invalid() }
        return (subject, payload["email"] as? String ?? "ChatGPT account")
    }
}

extension Data {
    var base64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    init?(base64URL text: String) {
        let standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        self.init(base64Encoded: standard + String(repeating: "=", count: (4 - standard.count % 4) % 4))
    }
}

protocol ChatGPTCredentialStore: Sendable {
    func read() throws -> Data?
    func write(_ data: Data) throws
}
struct ChatGPTKeychain: ChatGPTCredentialStore {
    private var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "app.wavepod.chatgpt", kSecAttrAccount as String: "accounts"] }
    func read() throws -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw EngineError.unavailable("Unlock Keychain to use your ChatGPT connection.") }
        return result as? Data
    }
    func write(_ data: Data) throws {
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw EngineError.unavailable("wavepod could not save the ChatGPT connection in the Keychain.") }
    }
}
