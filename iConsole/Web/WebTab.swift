import AppKit
import WebKit
import Observation

/// 탭 하나 = 웹뷰 하나. 같은 계정의 탭들은 웹 저장소(로그인)를 같이 쓴다.
/// 되살린 탭은 처음 보일 때까지 페이지를 읽지 않는다 (pending)
@Observable @MainActor
final class WebTab: Identifiable {
	let id = UUID()
	let webView: WKWebView
	private(set) var title = ""
	private(set) var url: URL?
	private(set) var isLoading = false
	private(set) var progress = 0.0
	private(set) var canGoBack = false
	private(set) var canGoForward = false
	/// 아직 읽지 않은 주소 (되살린 탭)
	private(set) var pending: URL?
	/// 번역해서 보는 중 (PageTranslator). 다른 페이지로 가도 이어서 번역한다
	var translated = false
	/// 이 탭 페이지가 알려 준 아이콘 주소 (탭마다 따로, 다른 탭 아이콘에 덮이지 않게)
	var icon: String?

	@ObservationIgnored private var observers: [NSKeyValueObservation] = []
	/// 주소·제목이 바뀌면 (탭 기억 저장)
	@ObservationIgnored var onChange: (() -> Void)?

	init(webView: WKWebView, pending: URL? = nil, title: String = "") {
		self.webView = webView
		self.pending = pending
		self.url = pending
		self.title = title
		observers = [
			webView.observe(\.title) { [weak self] w, _ in MainActor.assumeIsolated { self?.update(w) } },
			webView.observe(\.url) { [weak self] w, _ in MainActor.assumeIsolated { self?.update(w) } },
			webView.observe(\.isLoading) { [weak self] w, _ in MainActor.assumeIsolated { self?.update(w) } },
			webView.observe(\.estimatedProgress) { [weak self] w, _ in MainActor.assumeIsolated { self?.progress = w.estimatedProgress } },
			webView.observe(\.canGoBack) { [weak self] w, _ in MainActor.assumeIsolated { self?.canGoBack = w.canGoBack } },
			webView.observe(\.canGoForward) { [weak self] w, _ in MainActor.assumeIsolated { self?.canGoForward = w.canGoForward } },
		]
	}

	private func update(_ w: WKWebView) {
		guard pending == nil else { return }
		// 탭 이름은 늘 사이트가 주는 제목 (사용자 2026-11-23). 새 페이지라 아직 제목이 없으면 비워 두고 주소 호스트를 보인다
		let t = w.title ?? ""
		let changed = t != title || (w.url != nil && w.url != url)
		title = t
		if let u = w.url { url = u }
		isLoading = w.isLoading
		if changed { onChange?() }
	}

	/// 보일 때 한 번: 되살린 탭이면 이제 읽는다
	func wake() {
		guard let p = pending else { return }
		pending = nil
		webView.load(URLRequest(url: p))
	}

	func load(_ u: URL) {
		pending = nil
		url = u
		webView.load(URLRequest(url: u))
	}

	/// MCP 에 보이는 짧은 탭 id
	var shortID: String { String(id.uuidString.prefix(8)).lowercased() }

	/// 탭 이름: 제목 → 주소의 호스트 → "새 탭"
	var displayTitle: String {
		if !title.isEmpty { return title }
		return url?.host() ?? "새 탭"
	}
}
