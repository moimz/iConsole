import AppKit
import WebKit
import Observation

/// 계정 하나의 탭 묶음. 웹 저장소는 계정마다 하나(계정 UUID)이고, 그 계정의 탭들이 같이 쓴다.
/// 사이드바에서 계정을 바꾸면 이 묶음이 통째로 바뀌어 보인다 (웹뷰는 살아 있어 로그인·페이지 그대로)
@Observable @MainActor
final class AccountSession: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, WKScriptMessageHandlerWithReply, WKHTTPCookieStoreObserver {
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
		// 오른쪽 클릭 "요소 검사" (웹 속성 검사기). isInspectable 만으로는 Safari 개발자용 메뉴로만 붙는다
		config.preferences.setValue(true, forKey: "developerExtrasEnabled")
		let ucc = WKUserContentController()
		ucc.addUserScript(WKUserScript(source: Scripts.probe, injectionTime: .atDocumentStart, forMainFrameOnly: true))
		ucc.add(self, name: "ic")
		// 채우기 스크립트는 따로 떨어진 스크립트 세계에서. 애플 로그인 폼은 iframe 안이라 안쪽 프레임에도 넣는다
		ucc.addUserScript(WKUserScript(source: Scripts.filler, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: world))
		ucc.addScriptMessageHandler(self, contentWorld: world, name: "icfill")
		config.userContentController = ucc
		config.websiteDataStore.httpCookieStore.add(self)
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
		w.appearance = model?.webViewAppearance
		return w
	}

	@discardableResult
	private func add(_ tab: WebTab, after: WebTab.ID? = nil, activate: Bool) -> WebTab {
		tab.onChange = { [weak self, weak tab] in self?.saveTabs(); if let tab { self?.scheduleIcon(tab) } }
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
		t.onChange = { [weak self, weak t] in self?.saveTabs(); if let t { self?.scheduleIcon(t) } }
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

	func applyAppearance(_ a: NSAppearance?) {
		for t in tabs { t.webView.appearance = a }
		for w in popups { w.contentView?.appearance = a }
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

	// MARK: 탭 기억 (계정마다 열려 있던 탭을 다시 켤 때 되살린다. 맥마다 따로, 동기화하지 않는다 — 사용자 2026-11-23)

	private struct Memory: Codable {
		struct Tab: Codable { var url: String; var title: String }
		var tabs: [Tab]
		var active: Int
	}

	/// 이 맥 UserDefaults "tabs.<계정 UUID>"
	private var memoryKey: String { "tabs.\(accountID.uuidString)" }
	/// 마지막으로 쓴 내용 (같은 내용을 거듭 쓰지 않게)
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
		UserDefaults.standard.set(d, forKey: memoryKey)
	}

	/// 앱을 끝낼 때 (모아 둔 것을 바로 쓴다)
	func flush() {
		saveWork?.cancel()
		writeTabs()
	}

	private func restore(home: URL) {
		guard let d = UserDefaults.standard.data(forKey: memoryKey), let m = try? JSONDecoder().decode(Memory.self, from: d), !m.tabs.isEmpty else {
			newTab(home)
			return
		}
		for s in m.tabs {
			guard let u = URL(string: s.url) else { continue }
			let t = WebTab(webView: makeWebView(config), pending: u, title: s.title)
			t.onChange = { [weak self, weak t] in self?.saveTabs(); if let t { self?.scheduleIcon(t) } }
			tabs.append(t)
		}
		if tabs.isEmpty { newTab(home) } else { select(tabs[min(max(0, m.active), tabs.count - 1)].id) }
	}

	private func tab(of w: WKWebView) -> WebTab? { tabs.first { $0.webView === w } }

	private func log(_ s: String) { model?.log("[\(account?.name ?? "?")] \(s)") }

	// MARK: 세션 쿠키 살려 두기

	/// 애플 개발자 사이트처럼 로그인 쿠키(myacinfo 등)를 "세션 쿠키"(만료 없음)로 주는 곳은
	/// 앱을 끄면 WebKit 이 지워서 다시 켤 때마다 로그인이 풀렸다 (사용자 2026-11-23: 애플이 자주 풀린다).
	/// 쿠키가 바뀌면 잠깐 모았다가 세션 쿠키를 30일짜리 쿠키로 다시 넣는다 (서버가 정한 만료는 어쩔 수 없다)
	@ObservationIgnored private var cookieWork: DispatchWorkItem?
	static let keepSessionDays: Double = 30
	/// 세션 쿠키를 오래 남길 도메인
	static let keepDomains = ["apple.com"]

	nonisolated func cookiesDidChange(in store: WKHTTPCookieStore) {
		Task { @MainActor in self.scheduleCookieKeep(store) }
	}

	private func scheduleCookieKeep(_ store: WKHTTPCookieStore) {
		cookieWork?.cancel()
		let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.keepSessionCookies(store) } }
		cookieWork = work
		DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
	}

	private func keepSessionCookies(_ store: WKHTTPCookieStore) {
		Task { @MainActor in
			let cookies = await store.allCookies()
			var kept = 0
			// 애플 도메인만 (애플 개발자 로그인 쿠키 myacinfo 등이 세션 쿠키라 넣은 것).
			// 모든 사이트에 했더니 네이버처럼 세션 쿠키(NID_SES)를 계속 바꾸는 곳은 다시 써 넣은 쿠키와 꼬여 새로고침하면 로그아웃됐다 (사용자 2026-11-26)
			for c in cookies where c.isSessionOnly && Self.keepDomains.contains(where: { c.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).hasSuffix($0) }) {
				var p = c.properties ?? [:]
				p.removeValue(forKey: .discard)
				p.removeValue(forKey: .maximumAge)
				p[.expires] = Date().addingTimeInterval(Self.keepSessionDays * 86400)
				if let n = HTTPCookie(properties: p) { await store.setCookie(n); kept += 1 }
			}
			if kept > 0 { log("세션 쿠키 \(kept)개를 \(Int(Self.keepSessionDays))일 쿠키로 남김") }
		}
	}

	// MARK: 이동

	func webView(_ w: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
		// 가운데 버튼·⌘ 누르고 링크 누르기 → 뒤에 새 탭 (⌘⇧ 이면 그 탭으로)
		if action.navigationType == .linkActivated, let u = action.request.url,
		   action.buttonNumber == 2 || action.buttonNumber == 4 || action.modifierFlags.contains(.command) {
			newTab(u, activate: action.modifierFlags.contains(.shift), afterActive: true)
			return .cancel
		}
		// <a download> · blob: 저장 같은 것
		if action.shouldPerformDownload { return .download }
		return .allow
	}

	// MARK: 파일 받기 (받는 일은 Downloads)

	/// 보일 수 없는 형식이거나 서버가 "첨부"라고 하면 받는다
	func webView(_ w: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
		let disposition = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
		if !response.canShowMIMEType || disposition.lowercased().hasPrefix("attachment") { return .download }
		return .allow
	}

	func webView(_ w: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
		Downloads.shared.start(download, from: w, account: account?.name)
	}

	func webView(_ w: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
		Downloads.shared.start(download, from: w, account: account?.name)
		// target="_blank" 링크로 받으면 빈 탭 · 창만 남는다 → 닫는다 (Safari 처럼)
		guard w.backForwardList.currentItem == nil else { return }
		if let win = popups.first(where: { $0.contentView === w }) {
			win.close()
			popups.removeAll { $0 === win }
		} else if let t = tab(of: w), tabs.count > 1 {
			close(t.id)
		}
	}

	/// 다 읽으면 사이트 아이콘 주소를 찾아 받는다
	func webView(_ w: WKWebView, didFinish navigation: WKNavigation!) {
		if let t = tab(of: w) { refreshIcon(t) }
	}

	/// 그 탭 페이지의 아이콘 주소를 읽어 탭에 두고, 페이지 → 아이콘 짝을 기억한다.
	/// AWS 콘솔처럼 페이지를 다시 읽지 않고 바꾸는 곳(SPA)은 주소·제목이 바뀔 때도 (잠깐 뒤에) 다시 읽는다
	private func refreshIcon(_ t: WebTab) {
		guard let page = t.webView.url, page.scheme?.hasPrefix("http") == true else { return }
		t.webView.evaluateJavaScript(Favicons.finder) { result, _ in
			MainActor.assumeIsolated {
				guard let s = result as? String, let u = URL(string: s) else { return }
				t.icon = s
				Favicons.shared.record(page: page, icon: u)
			}
		}
	}

	@ObservationIgnored private var iconWork: [WebTab.ID: DispatchWorkItem] = [:]

	private func scheduleIcon(_ t: WebTab) {
		iconWork[t.id]?.cancel()
		let work = DispatchWorkItem { [weak self, weak t] in
			MainActor.assumeIsolated { if let self, let t { self.refreshIcon(t) } }
		}
		iconWork[t.id] = work
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
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

	/// 칸 옆 다시 채우기 버튼 아이콘: SF Symbol lock.rotation 을 흰색 PNG(2배) data 주소로 (웹에선 SF Symbol 을 못 쓴다, 사용자 2026-11-26)
	private static let retryIcon: String = {
		let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold).applying(.init(paletteColors: [.white]))
		guard let sym = NSImage(systemSymbolName: "lock.rotation", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return "" }
		let size = sym.size
		guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
		                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return "" }
		rep.size = size
		NSGraphicsContext.saveGraphicsState()
		NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
		sym.draw(in: NSRect(origin: .zero, size: size))
		NSGraphicsContext.restoreGraphicsState()
		guard let png = rep.representation(using: .png, properties: [:]) else { return "" }
		return "data:image/png;base64," + png.base64EncodedString() + "#\(Int(size.width))x\(Int(size.height))"
	}()

	func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
		guard let a = account, let body = message.body as? [String: Any], let op = body["op"] as? String else {
			replyHandler(nil, nil); return
		}
		// 값을 넘기는 조건: https 프레임 주소가 그 계정 종류의 로그인 도메인이고,
		// 안쪽 프레임이면(애플 로그인은 iframe 안) 바깥 페이지 주소도 로그인 도메인
		let f = message.frameInfo
		let isLogin = { (h: String) in a.loginHosts.contains { h == $0 || h.hasSuffix("." + $0) } }
		let top = message.webView?.url
		let trusted = f.securityOrigin.protocol == "https" && isLogin(f.securityOrigin.host.lowercased())
			&& (f.isMainFrame || (top?.scheme == "https" && isLogin(top?.host()?.lowercased() ?? "")))
		switch op {
		case "hello":
			// 로그인 같아 보이는 페이지인데 로그인 도메인이 아니면 기록에 남긴다 (사이트가 로그인 주소를 옮긴 걸 알아채게)
			if !trusted, f.isMainFrame, let u = top, (u.host() ?? "").range(of: "signin|login|auth|account", options: .regularExpression) != nil {
				log("채우지 않음 — 로그인 도메인(\(a.loginHosts.joined(separator: ", ")))이 아님: \(u.host() ?? "")\(u.path())")
			}
			replyHandler(trusted ? ["autoSubmit": model?.autoSubmit ?? false, "kind": a.kind.rawValue, "fields": a.fields, "icon": Self.retryIcon] : nil, nil)
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
		case "copy":
			// 열쇠 버튼으로 넣어도 칸에 남지 않을 때: 값을 클립보드에 (암호 · 코드는 다른 클립보드 앱이 기록하지 않게 표시하고 1분 뒤 지운다)
			guard trusted, let field = body["field"] as? String else { replyHandler(false, nil); return }
			let value: String? = switch field {
			case "username": a.username
			case "password": Keychain.get(a.passwordKey)
			case "otp": Keychain.get(a.otpKey).flatMap(TOTP.init)?.code()
			default: nil
			}
			guard let value, !value.isEmpty else { replyHandler(false, nil); return }
			let pb = NSPasteboard.general
			pb.clearContents()
			pb.setString(value, forType: .string)
			if field != "username" {
				pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
				let n = pb.changeCount
				DispatchQueue.main.asyncAfter(deadline: .now() + 60) { if pb.changeCount == n { pb.clearContents() } }
			}
			log("\(field == "otp" ? "OTP" : field == "password" ? "암호" : "아이디") 클립보드에 복사")
			replyHandler(true, nil)
		case "log":
			log(body["text"] as? String ?? "")
			replyHandler(nil, nil)
		default:
			replyHandler(nil, nil)
		}
	}
}
