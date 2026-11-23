import AppKit
import AuthenticationServices

/// iConsole 자동 완성 확장 (자격 증명 제공자).
/// 1) 암호 앱 "선택한 항목을 앱으로 내보내기" 의 받는 쪽으로 iConsole 이 목록에 나오게 한다 (Info.plist SupportedCredentialExchangeFormatVersions).
///    실제 가져오기는 iConsole 앱이 ASCredentialImportManager 로 한다.
/// 2) Safari · Chrome 자동 완성: iConsole 설정에서 켠 때만 앱이 키체인에 "autofill.index" 를 써 두고, 이 확장은 그 목록의 계정 암호만 내준다.
///    목록이 없으면(설정에서 끔) 무엇을 물어도 아무것도 내주지 않고 닫는다 → 시스템 설정에서 iConsole 을 켜 둬도 영향이 없다.
final class CredentialProviderViewController: ASCredentialProviderViewController {
	/// 앱이 써 둔 자동 완성 목록의 한 줄 (앱 Model/Autofill.swift 의 AutofillEntry 와 같은 모양)
	struct Entry: Codable {
		let id: String
		let name: String
		let user: String
		let hosts: [String]
	}

	private var entries: [Entry] {
		guard let d = Self.keychain("autofill.index"), let e = try? JSONDecoder().decode([Entry].self, from: d) else { return [] }
		return e
	}

	override func loadView() {
		view = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 260))
	}

	// MARK: 목록에서 고르기 (Safari 의 열쇠 · "iConsole" 고르기)

	override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
		let all = entries
		guard !all.isEmpty else { return cancel(.userCanceled) }
		let hosts = serviceIdentifiers.compactMap(Self.host)
		let matched = all.filter { e in hosts.contains { h in e.hosts.contains { h == $0 || h.hasSuffix("." + $0) } } }
		showList(matched.isEmpty ? all : matched)
	}

	// MARK: 바로 채우기 (추천 줄을 고른 때)

	override func provideCredentialWithoutUserInteraction(for credentialRequest: any ASCredentialRequest) {
		guard let c = credential(for: credentialRequest.credentialIdentity.recordIdentifier) else { return cancel(.userInteractionRequired) }
		extensionContext.completeRequest(withSelectedCredential: c, completionHandler: nil)
	}

	override func prepareInterfaceToProvideCredential(for credentialRequest: any ASCredentialRequest) {
		guard let c = credential(for: credentialRequest.credentialIdentity.recordIdentifier) else { return cancel(.credentialIdentityNotFound) }
		extensionContext.completeRequest(withSelectedCredential: c, completionHandler: nil)
	}

	// MARK: 패스키 · 인증 코드 요청은 내주지 않는다 (Info.plist 에는 받는다고 선언만)

	override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier], requestParameters: ASPasskeyCredentialRequestParameters) {
		prepareCredentialList(for: serviceIdentifiers)
	}

	override func prepareOneTimeCodeCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
		cancel(.userCanceled)
	}

	// MARK: 작은 도움

	private func credential(for id: String?) -> ASPasswordCredential? {
		guard let id, let e = entries.first(where: { $0.id == id }),
		      let d = Self.keychain("\(id).password"), let pw = String(data: d, encoding: .utf8) else { return nil }
		return ASPasswordCredential(user: e.user, password: pw)
	}

	private func cancel(_ code: ASExtensionError.Code) {
		extensionContext.cancelRequest(withError: NSError(domain: ASExtensionErrorDomain, code: code.rawValue))
	}

	private func showList(_ list: [Entry]) {
		let stack = NSStackView()
		stack.orientation = .vertical
		stack.alignment = .leading
		stack.spacing = 8
		stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
		let title = NSTextField(labelWithString: "iConsole 계정")
		title.font = .boldSystemFont(ofSize: 13)
		stack.addArrangedSubview(title)
		for e in list {
			let b = NSButton(title: "\(e.name) — \(e.user)", target: self, action: #selector(pick(_:)))
			b.identifier = NSUserInterfaceItemIdentifier(e.id)
			b.bezelStyle = .push
			stack.addArrangedSubview(b)
		}
		let close = NSButton(title: "취소", target: self, action: #selector(cancelTapped))
		stack.addArrangedSubview(close)
		stack.translatesAutoresizingMaskIntoConstraints = false
		view.addSubview(stack)
		NSLayoutConstraint.activate([
			stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			stack.topAnchor.constraint(equalTo: view.topAnchor),
		])
	}

	@objc private func pick(_ sender: NSButton) {
		guard let c = credential(for: sender.identifier?.rawValue) else { return cancel(.credentialIdentityNotFound) }
		extensionContext.completeRequest(withSelectedCredential: c, completionHandler: nil)
	}

	@objc private func cancelTapped() { cancel(.userCanceled) }

	private static func host(_ s: ASCredentialServiceIdentifier) -> String? {
		let raw = s.identifier
		let h = (URL(string: raw)?.host() ?? raw).lowercased()
		return h.isEmpty ? nil : h
	}

	/// 앱과 같은 접근 그룹의 키체인 (iCloud 동기화 항목 · 이 맥 항목 모두)
	private static func keychain(_ key: String) -> Data? {
		let q: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: "com.moimz.iConsole",
			kSecAttrAccount as String: key,
			kSecUseDataProtectionKeychain as String: true,
			kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
			kSecReturnData as String: true,
			kSecMatchLimit as String: kSecMatchLimitOne,
		]
		var out: CFTypeRef?
		guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
		return out as? Data
	}
}
