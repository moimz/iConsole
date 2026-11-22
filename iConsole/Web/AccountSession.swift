import AppKit
import WebKit
import Observation

/// 계정 하나의 탭 묶음. 웹 저장소는 계정마다 하나(계정 UUID)이고, 그 계정의 탭들이 같이 쓴다.
/// 사이드바에서 계정을 바꾸면 이 묶음이 통째로 바뀌어 보인다 (웹뷰는 살아 있어 로그인·페이지 그대로)
@Observable @MainActor
final class AccountSession: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, WKScriptMessageHandlerWithReply {
	let accountID: UUID
	private(set) var tabs: [WebTab] = []
	private(set) var activeID: WebTab.ID?
	/// 닫은 탭 (⌘⇧T 로 다시 열기, 최근 20개)
	@ObservationIgnored private var closed: [(url: URL, index: Int)] = []

	@ObservationIgnored private weak var model: AppModel?
	@ObservationIgnored private let config: WKWebViewConfiguration
	@ObservationIgnored private var popups: [NSWindow] = []
	@ObservationIgnored private let world = WKContentWorld.world(name: "iconsole")

	init(account: Account, model: AppModel) {
		accountID = account.id
		self.model = model
		config = WKWebViewConfiguration()
		super.init()
		config.websiteDataStore = WKWebsiteDataStore(forIdentifier: account.id)
		config.preferences.javaScriptCanOpenWindowsAutomatically = true
		let ucc = WKUserContentController()
		ucc.addUserScript(WKUserScript(source: Scripts.probe, injectionTime: .atDocumentStart, forMainFrameOnly: true))
		ucc.add(self, name: "ic")
		// 채우기 스크립트는 따로 떨어진 스크립트 세계에서. 애플 로그인 폼은 iframe 안이라 안쪽 프레임에도 넣는다
		ucc.addUserScript(WKUserScript(source: Scripts.filler, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: world))
		ucc.addScriptMessageHandler(self, contentWorld: world, name: "icfill")
		config.userContentController = ucc
		restore(home: account.home)
	}

	var account: Account? { model?.store.account(accountID) }
	var active: WebTab? { tabs.first { $0.id == activeID } }

	// MARK: 탭

	private func makeWebView(_ c: WKWebViewConfiguration) -> WKWebView {
		let w = WKWebView(frame: .zero, configuration: c)
		w.navigationDelegate = self
		w.uiDelegate = self
		w.isInspectable = true
		w.allowsBackForwardNavigationGestures = true
		w.customUserAgent = model?.userAgent
		return w
	}

	@discardableResult
	private func add(_ tab: WebTab, after: WebTab.ID? = nil, activate: Bool) -> WebTab {
		tab.onChange = { [weak self] in self?.saveTabs() }
		if let after, let i = tabs.firstIndex(where: { $0.id == after }) { tabs.insert(tab, at: i + 1) } else { tabs.append(tab) }
		if activate || activeID == nil { select(tab.id) }
		saveTabs()
		return tab
	}

	/// 새 탭 (주소가 없으면 계정 시작 주소)
	@discardableResult
	func newTab(_ url: URL? = nil, activate: Bool = true, afterActive: Bool = false) -> WebTab {
		let t = WebTab(webView: makeWebView(config))
		add(t, after: afterActive ? activeID : nil, activate: activate)
		t.load(url ?? account?.home ?? URL(string: "about:blank")!)
		return t
	}

	func select(_ id: WebTab.ID) {
		activeID = id
		active?.wake()
		saveTabs()
	}

	func close(_ id: WebTab.ID) {
		guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
		let t = tabs.remove(at: i)
		if let u = t.url ?? t.pending { closed.append((u, i)); if closed.count > 20 { closed.removeFirst() } }
		t.webView.stopLoading()
		t.webView.removeFromSuperview()
		if activeID == id {
			activeID = nil
			if !tabs.isEmpty { select(tabs[min(i, tabs.count - 1)].id) }
		}
		saveTabs()
	}

	func closeOthers(_ id: WebTab.ID) {
		for t in tabs where t.id != id { close(t.id) }
	}

	func reopenClosed() {
		guard let last = closed.popLast() else { NSSound.beep(); return }
		let t = WebTab(webView: makeWebView(config))
		t.onChange = { [weak self] in self?.saveTabs() }
		tabs.insert(t, at: min(last.index, tabs.count))
		select(t.id)
		t.load(last.url)
	}

	func move(_ id: WebTab.ID, before target: WebTab.ID?) {
		guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
		let t = tabs.remove(at: i)
		if let target, let j = tabs.firstIndex(where: { $0.id == target }) { tabs.insert(t, at: j) } else { tabs.append(t) }
		saveTabs()
	}

	/// 옆 탭으로 (⌃Tab · ⌃⇧Tab)
	func cycle(_ step: Int) {
		guard let i = tabs.firstIndex(where: { $0.id == activeID }), tabs.count > 1 else { return }
		select(tabs[(i + step + tabs.count) % tabs.count].id)
	}

	/// 이미 그 주소 탭이 있으면 그 탭으로, 없으면 새 탭 (사이드바 즐겨찾기)
	func show(_ url: URL) {
		if let t = tabs.first(where: { $0.url?.absoluteString == url.absoluteString }) { select(t.id) } else { newTab(url) }
	}

	func applyUserAgent(_ ua: String?) {
		for t in tabs { t.webView.customUserAgent = ua; if t.pending == nil { t.webView.reload() } }
	}

	/// 계정을 지울 때: 웹뷰·창을 치우고 스크립트 연결을 끊는다 (WKUserContentController 가 이 객체를 붙잡고 있다)
	func tearDown() {
		saveWork?.cancel()
		for t in tabs { t.webView.stopLoading(); t.webView.removeFromSuperview() }
		tabs.removeAll()
		popups.forEach { $0.close() }
		config.userContentController.removeAllScriptMessageHandlers()
	}

	// MARK: 탭 기억 (계정마다 열려 있던 탭. iCloud 로 맥끼리 같이 쓰고, 그 계정을 처음 열 때 되살린다)

	private struct Memory: Codable {
		struct Tab: Codable { var url: String; var title: String }
		var tabs: [Tab]
		var active: Int
	}

	/// iCloud Drive Tabs/<계정 UUID>.json (예전에는 UserDefaults "tabs.<id>" 에 맥마다 따로)
	private var memoryFile: URL { StorageLocation.shared.tabs.appendingPathComponent(accountID.uuidString + ".json") }
	private var legacyKey: String { "tabs.\(accountID.uuidString)" }
	/// 마지막으로 쓴 내용 (같은 내용을 iCloud 에 거듭 쓰지 않게)
	@ObservationIgnored private var lastSaved: Data?
	@ObservationIgnored private var saveWork: DispatchWorkItem?

	/// 주소·제목은 자주 바뀌니 잠깐 모았다가 쓴다
	private func saveTabs() {
		saveWork?.cancel()
		let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.writeTabs() } }
		saveWork = work
		DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
	}

	private func writeTabs() {
		let list = tabs.compactMap { t in (t.url ?? t.pending).map { Memory.Tab(url: $0.absoluteString, title: t.title) } }
		let m = Memory(tabs: list, active: tabs.firstIndex { $0.id == activeID } ?? 0)
		guard let d = try? JSONEncoder().encode(m), d != lastSaved else { return }
		lastSaved = d
		StorageLocation.write(d, to: memoryFile)
	}

	/// 앱을 끝낼 때 (모아 둔 것을 바로 쓴다)
	func flush() {
		saveWork?.cancel()
		writeTabs()
	}

	private func restore(home: URL) {
		let d = StorageLocation.read(memoryFile) ?? UserDefaults.standard.data(forKey: legacyKey)
		UserDefaults.standard.removeObject(forKey: legacyKey)
		guard let d, let m = try? JSONDecoder().decode(Memory.self, from: d), !m.tabs.isEmpty else {
			newTab(home)
			return
		}
		for s in m.tabs {
			guard let u = URL(string: s.url) else { continue }
			let t = WebTab(webView: makeWebView(config), pending: u, title: s.title)
			t.onChange = { [weak self] in self?.saveTabs() }
			tabs.append(t)
		}
		if tabs.isEmpty { newTab(home) } else { select(tabs[min(max(0, m.active), tabs.count - 1)].id) }
	}

	private func tab(of w: WKWebView) -> WebTab? { tabs.first { $0.webView === w } }

	private func log(_ s: String) { model?.log("[\(account?.name ?? "?")] \(s)") }

	// MARK: 이동

	func webView(_ w: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
		// 가운데 버튼·⌘ 누르고 링크 누르기 → 뒤에 새 탭 (⌘⇧ 이면 그 탭으로)
		if action.navigationType == .linkActivated, let u = action.request.url,
		   action.buttonNumber == 2 || action.buttonNumber == 4 || action.modifierFlags.contains(.command) {
			newTab(u, activate: action.modifierFlags.contains(.shift), afterActive: true)
			return .cancel
		}
		return .allow
	}

	/// 다 읽으면 사이트 아이콘 주소를 찾아 받는다
	func webView(_ w: WKWebView, didFinish navigation: WKNavigation!) {
		guard let host = w.url?.host() else { return }
		w.evaluateJavaScript(Favicons.finder) { result, _ in
			MainActor.assumeIsolated {
				if let s = result as? String, let u = URL(string: s) { Favicons.shared.fetch(u, host: host) }
			}
		}
	}

	func webView(_ w: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError e: Error) {
		if (e as NSError).code != NSURLErrorCancelled { log("열지 못함: \(e.localizedDescription)") }
	}

	func webViewWebContentProcessDidTerminate(_ w: WKWebView) {
		log("페이지가 멈춰 다시 읽음")
		w.reload()
	}

	// MARK: 새 창 → 탭 (크기를 정해 여는 창은 OAuth 같은 팝업이라 따로 된 창)

	func webView(_ w: WKWebView, createWebViewWith c: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures f: WKWindowFeatures) -> WKWebView? {
		let nw = makeWebView(c)
		if f.width != nil || f.height != nil {
			let size = NSSize(width: f.width?.doubleValue ?? 520, height: f.height?.doubleValue ?? 720)
			let win = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
			win.isReleasedWhenClosed = false
			win.title = action.request.url?.host() ?? "팝업"
			win.contentView = nw
			win.center()
			win.makeKeyAndOrderFront(nil)
			popups.append(win)
		} else {
			add(WebTab(webView: nw), after: tab(of: w)?.id ?? activeID, activate: true)
		}
		return nw
	}

	func webViewDidClose(_ w: WKWebView) {
		if let win = popups.first(where: { $0.contentView === w }) {
			win.close()
			popups.removeAll { $0 === win }
		} else if let t = tab(of: w) {
			close(t.id)
		}
	}

	func webView(_ w: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
		let a = NSAlert(); a.messageText = message; a.runModal()
	}

	func webView(_ w: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
		let a = NSAlert(); a.messageText = message; a.addButton(withTitle: "확인"); a.addButton(withTitle: "취소")
		return a.runModal() == .alertFirstButtonReturn
	}

	func webView(_ w: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
		let p = NSOpenPanel()
		p.allowsMultipleSelection = parameters.allowsMultipleSelection
		p.canChooseDirectories = parameters.allowsDirectories
		return p.runModal() == .OK ? p.urls : nil
	}

	// MARK: 페이지 기록 (page 세계)

	func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
		log("\(message.body)")
	}

	// MARK: 채우기 (iconsole 세계)

	func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
		guard let a = account, let body = message.body as? [String: Any], let op = body["op"] as? String else {
			replyHandler(nil, nil); return
		}
		// 값을 넘기는 조건: https 프레임 주소가 그 계정 종류의 로그인 도메인이고,
		// 안쪽 프레임이면(애플 로그인은 iframe 안) 바깥 페이지 주소도 로그인 도메인
		let f = message.frameInfo
		let isLogin = { (h: String) in a.kind.loginHosts.contains { h == $0 || h.hasSuffix("." + $0) } }
		let top = message.webView?.url
		let trusted = f.securityOrigin.protocol == "https" && isLogin(f.securityOrigin.host.lowercased())
			&& (f.isMainFrame || (top?.scheme == "https" && isLogin(top?.host()?.lowercased() ?? "")))
		switch op {
		case "hello":
			replyHandler(trusted ? ["autoSubmit": model?.autoSubmit ?? false, "kind": a.kind.rawValue] : nil, nil)
		case "get":
			guard trusted, let field = body["field"] as? String else { replyHandler(nil, nil); return }
			switch field {
			case "username":
				log("아이디 채움")
				replyHandler(a.username, nil)
			case "password":
				let p = Keychain.get(a.passwordKey)
				log("암호 \(p == nil ? "없음" : "채움")")
				replyHandler(p, nil)
			case "otp":
				let t = Keychain.get(a.otpKey).flatMap(TOTP.init)
				log("OTP \(t.map { "채움 (\($0.remaining())초 남음)" } ?? "없음")")
				replyHandler(t?.code(), nil)
			default:
				replyHandler(nil, nil)
			}
		case "log":
			log(body["text"] as? String ?? "")
			replyHandler(nil, nil)
		default:
			replyHandler(nil, nil)
		}
	}
}
