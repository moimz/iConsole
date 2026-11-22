import AppKit
import WebKit
import Observation

/// 앱 전체 상태: 계정 목록, 계정별 탭 묶음(처음 고를 때 만든다), 지금 계정, 설정, 기록
@Observable @MainActor
final class AppModel {
	let store = AccountStore()
	private(set) var sessions: [UUID: AccountSession] = [:]
	/// 지금 보고 있는 계정
	private(set) var currentID: UUID?
	private(set) var logs: [String] = []
	/// 주소칸 (⌘L 로 초점)
	@ObservationIgnored let address = AddressController()

	/// 로그인 칸을 채운 뒤 다음 버튼까지 누를지 (기본은 채우기만, 엔터는 사용자가)
	var autoSubmit = UserDefaults.standard.bool(forKey: "autoSubmit2") {
		didSet { UserDefaults.standard.set(autoSubmit, forKey: "autoSubmit2") }
	}
	/// Safari 처럼 보이는 UA ("Version/… Safari/…" 꼬리)
	var safariUA = UserDefaults.standard.bool(forKey: "safariUA") {
		didSet {
			UserDefaults.standard.set(safariUA, forKey: "safariUA")
			sessions.values.forEach { $0.applyUserAgent(userAgent) }
		}
	}

	var userAgent: String? {
		safariUA ? "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15" : nil
	}

	init() {
		Keychain.probe()
		NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
			MainActor.assumeIsolated { self?.flush() }
		}
		store.moveSecretsToCloud()
		// 다른 맥에서 계정·그룹·즐겨찾기가 바뀌면 다시 읽는다 (지워진 계정은 탭도 닫는다)
		CloudWatcher.shared.start { [weak self] in
			MainActor.assumeIsolated { self?.reloadFromCloud() }
		}
		// 마지막에 보던 계정
		if let s = UserDefaults.standard.string(forKey: "current"), let id = UUID(uuidString: s), store.account(id) != nil {
			currentID = id
		}
	}

	private func reloadFromCloud() {
		store.load()
		Favicons.shared.reload()
		for (id, s) in sessions where store.account(id) == nil {
			s.tearDown()
			sessions[id] = nil
			UserDefaults.standard.removeObject(forKey: "tabs.\(id.uuidString)")
			Task { try? await WKWebsiteDataStore.remove(forIdentifier: id) }
		}
		if let id = currentID, store.account(id) == nil { select(nil) }
	}

	var currentAccount: Account? { store.account(currentID) }
	var current: AccountSession? { currentID.map(session) }

	func session(_ id: UUID) -> AccountSession {
		if let s = sessions[id] { return s }
		let s = AccountSession(account: store.account(id)!, model: self)
		sessions[id] = s
		return s
	}

	func select(_ id: UUID?) {
		guard id != currentID else { return }
		currentID = id
		UserDefaults.standard.set(id?.uuidString, forKey: "current")
	}

	/// 즐겨찾기 시트 (제목바 아래로 붙는다): 추가할 때는 이름·주소를 채워서, 이미 있으면 편집
	var favoriteDraft: FavoriteDraft?

	/// ☆ · ⌘D · 탭 오른쪽 클릭: 없으면 추가 시트, 있으면 편집 시트
	func editFavorite(_ tab: WebTab? = nil) {
		guard let id = currentID, let t = tab ?? current?.active, let u = t.url else { return }
		if let f = favorite(for: u, in: id) {
			favoriteDraft = FavoriteDraft(accountID: id, favorite: f, isNew: false)
		} else {
			favoriteDraft = FavoriteDraft(accountID: id, favorite: Favorite(title: t.displayTitle, url: u.absoluteString), isNew: true)
		}
	}

	func favorite(for url: URL?, in id: UUID?) -> Favorite? {
		guard let url else { return nil }
		return store.account(id)?.favorites.first { $0.url == url.absoluteString }
	}

	/// 계정 삭제: 탭·웹 저장소·키체인 항목까지
	func delete(_ a: Account) {
		if let s = sessions.removeValue(forKey: a.id) { s.tearDown() }
		if currentID == a.id { select(nil) }
		store.delete(a)
		UserDefaults.standard.removeObject(forKey: "tabs.\(a.id.uuidString)")
		Task {
			try? await Task.sleep(for: .milliseconds(500))
			try? await WKWebsiteDataStore.remove(forIdentifier: a.id)
		}
	}

	/// 그 계정의 쿠키·로그인을 지운다 (탭은 시작 주소로 다시)
	func clearWebData(_ a: Account) async {
		await WKWebsiteDataStore(forIdentifier: a.id).removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
		log("[\(a.name)] 웹 데이터(로그인) 지움")
		if let s = sessions[a.id] { s.active?.load(a.home) }
	}

	/// 앱을 끝낼 때 모아 둔 탭 기억을 쓴다
	func flush() { sessions.values.forEach { $0.flush() } }

	func log(_ s: String) {
		let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
		logs.append("\(f.string(from: Date())) \(s)")
		if logs.count > 500 { logs.removeFirst(logs.count - 500) }
	}

	func clearLogs() { logs.removeAll() }
}

/// 즐겨찾기 시트에 넘기는 것
struct FavoriteDraft: Identifiable {
	var id: UUID { favorite.id }
	let accountID: UUID
	var favorite: Favorite
	let isNew: Bool
}
