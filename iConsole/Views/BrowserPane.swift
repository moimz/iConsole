import SwiftUI
import WebKit

/// 계정 하나의 화면: 제목줄 [‹ ›] [↻] · 가운데 [☆ 주소칸], 그 아래 즐겨찾기 막대(Safari 처럼), 탭 줄, 지금 탭의 웹뷰.
/// 제목줄 버튼은 이 본문 뷰의 .toolbar 에 붙인다 (창 전체 .toolbar 에 두면 사이드바 토글 밑에 깔렸다가 밀려 나온다, Ai.md 8·12번)
struct BrowserPane: View {
	@Environment(AppModel.self) private var model
	let session: AccountSession

	private var tab: WebTab? { session.active }

	var body: some View {
		VStack(spacing: 0) {
			FavoritesBar(session: session)
			Divider()
			TabBar(session: session)
			Divider()
			ZStack(alignment: .top) {
				WebArea(webView: tab?.webView)
				if session.tabs.isEmpty {
					ContentUnavailableView {
						Label("열린 탭 없음", systemImage: "rectangle.on.rectangle")
					} description: {
						Text("⌘T 로 새 탭을 엽니다")
					} actions: {
						Button("콘솔 열기") { session.newTab() }.buttonStyle(.borderedProminent)
					}
					.frame(maxWidth: .infinity, maxHeight: .infinity)
					.background(.background)
				}
			}
		}
		.toolbar {
			ToolbarItemGroup(placement: .navigation) {
				Button("뒤로", systemImage: "chevron.left") { tab?.webView.goBack() }
					.disabled(tab?.canGoBack != true)
					.help("뒤로 (⌘[)")
				Button("앞으로", systemImage: "chevron.right") { tab?.webView.goForward() }
					.disabled(tab?.canGoForward != true)
					.help("앞으로 (⌘])")
			}
			// 동작 자리(.primaryAction)는 제목을 숨긴 창에서 왼쪽부터 흐른다 → 양옆 빈 칸으로 주소칸을 가운데쯤에 (inPlayer 웹 탐색)
			ToolbarSpacer(.flexible)
			// Safari 처럼 한 알약 안에 [☆ 주소 ↻] (사용자 2026-11-23: 주소칸은 더 넓게, 새로고침은 주소칸에)
			ToolbarItemGroup(placement: .primaryAction) {
				let fav = model.favorite(for: tab?.url, in: session.accountID) != nil
				Button(fav ? "즐겨찾기 편집" : "즐겨찾기에 추가", systemImage: fav ? "star.fill" : "star") { model.editFavorite() }
					.disabled(tab?.url == nil)
					.help(fav ? "즐겨찾기 편집 (⌘D)" : "즐겨찾기에 추가 (⌘D)")
				AddressField(url: tab?.url, controller: model.address) { text in
					guard let u = Self.url(from: text) else { return }
					if let tab { tab.load(u) } else { session.newTab(u) }
				}
				.padding(.horizontal, 6)
				.frame(minWidth: 200, idealWidth: 900, maxWidth: 1200, minHeight: 28, maxHeight: 28)
				// 읽는 중: Safari 처럼 주소칸 아래쪽에 얇은 진행 막대 (예전엔 웹 영역 맨 위에 그렸다, 사용자 2026-11-23)
				.overlay(alignment: .bottomLeading) {
					if let tab, tab.isLoading {
						GeometryReader { g in
							Capsule().fill(Color.accentColor)
								.frame(width: max(8, g.size.width * tab.progress), height: 2)
								.frame(maxHeight: .infinity, alignment: .bottom)
								.animation(.easeOut(duration: 0.2), value: tab.progress)
						}
						.offset(y: 3)
						.allowsHitTesting(false)
					}
				}
				Button("새로고침", systemImage: tab?.isLoading == true ? "xmark" : "arrow.clockwise") {
					guard let tab else { return }
					if tab.isLoading { tab.webView.stopLoading() } else { tab.webView.reload() }
				}
				.disabled(tab == nil)
				.help(tab?.isLoading == true ? "멈추기" : "새로고침 (⌘R)")
			}
			ToolbarSpacer(.flexible)
			// 새 탭은 제목줄 오른쪽 끝 + 하나 (사용자 2026-11-23, 탭 줄의 + 는 뺐다)
			ToolbarItem(placement: .primaryAction) {
				Button("새 탭", systemImage: "plus") { session.newTab() }
					.help("새 탭 (⌘T)")
			}
		}
	}

	/// 주소칸 글 → 주소 (점이 있고 띄어쓰기가 없으면 https://, 아니면 구글 검색)
	static func url(from text: String) -> URL? {
		let s = text.trimmingCharacters(in: .whitespaces)
		if s.contains("://") { return URL(string: s) }
		if s.contains("."), !s.contains(" ") { return URL(string: "https://" + s) }
		var c = URLComponents(string: "https://www.google.com/search")!
		c.queryItems = [URLQueryItem(name: "q", value: s)]
		return c.url
	}
}

/// 탭 줄 (iSQL 탭바와 같은 모양: 끌어 순서 바꾸기, 넘치면 < >, 가운데 버튼으로 닫기)
struct TabBar: View {
	@Environment(AppModel.self) private var model
	let session: AccountSession
	@State private var reorder = TabReorder<WebTab.ID>()

	var body: some View {
		HStack(spacing: 0) {
			TabStrip(selected: session.activeID) {
				ForEach(session.tabs) { t in
					WebTabItem(tab: t, active: session.activeID == t.id,
					           favorite: model.favorite(for: t.url, in: session.accountID) != nil,
					           select: { session.select(t.id) },
					           close: { session.close(t.id) })
						.contextMenu {
							let fav = model.favorite(for: t.url, in: session.accountID) != nil
							Button(fav ? "즐겨찾기 편집…" : "즐겨찾기에 추가…") { model.editFavorite(t) }.disabled(t.url == nil)
							Button("주소 복사") {
								NSPasteboard.general.clearContents()
								NSPasteboard.general.setString(t.url?.absoluteString ?? "", forType: .string)
							}
							.disabled(t.url == nil)
							Button("탭 복제") { if let u = t.url { session.newTab(u, afterActive: true) } }.disabled(t.url == nil)
							Button("새로고침") { t.webView.reload() }
							Divider()
							Button("탭 닫기") { session.close(t.id) }
							Button("다른 탭 닫기") { session.closeOthers(t.id) }.disabled(session.tabs.count < 2)
						}
						.reorderable(t.id, order: session.tabs.map(\.id), state: $reorder) { session.move($0, before: $1) }
						.id(t.id)
				}
			}
			// 탭을 옮기면 탭바 안에서만 짧게 미끄러지게 (바깥 묶음에 animation 을 걸지 않는다, Ai/iSQL.md 성능 규칙)
			.animation(.easeOut(duration: 0.18), value: session.tabs.map(\.id))
		}
		.frame(height: 36)
		// 색 배경은 기본으로 제목바 밑까지 번진다 → 탭바 안에만 (Ai/iSQL.md)
		.background(Color(nsColor: .underPageBackgroundColor).opacity(0.5), ignoresSafeAreaEdges: [])
	}
}

/// 탭 하나: [로딩/★/지구] 제목 … [✕]
struct WebTabItem: View {
	let tab: WebTab
	let active: Bool
	let favorite: Bool
	let select: () -> Void
	let close: () -> Void
	@State private var hover = false

	var body: some View {
		HStack(spacing: 6) {
			Group {
				if tab.isLoading {
					ProgressView().controlSize(.mini)
				} else {
					FaviconView(url: tab.url, icon: tab.icon, size: 14)
				}
			}
			.frame(width: 14, height: 14)
			TabTitle(text: tab.displayTitle, active: active)
				.foregroundStyle(tab.pending != nil ? .secondary : .primary)
			Spacer(minLength: 4)
			Button(action: close) {
				Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
					.frame(width: 16, height: 16)
					.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			.foregroundStyle(.secondary)
			.opacity(hover || active ? 1 : 0)
			.help("탭 닫기 (⌘W)")
		}
		.padding(.leading, 12)
		.padding(.trailing, 6)
		.frame(height: 36)
		.frame(minWidth: 120, maxWidth: 240, alignment: .leading)
		.background(active ? Color(nsColor: .windowBackgroundColor) : (hover ? Color.primary.opacity(0.05) : .clear), ignoresSafeAreaEdges: [])
		.overlay(alignment: .top) { if active { Rectangle().fill(Color.accentColor).frame(height: 2) } }
		.overlay(alignment: .trailing) { Rectangle().fill(Color.secondary.opacity(0.2)).frame(width: 1) }
		.contentShape(Rectangle())
		.onHover { hover = $0 }
		// 누르는 순간 고른다 (닫기 버튼 자리는 빼고), 가운데 버튼은 닫기
		.onMouseDown(excludeTrailing: 24, perform: select)
		.background(MiddleClickCatcher(action: close))
		.help(tab.url?.absoluteString ?? tab.displayTitle)
	}
}

/// 탭 위 가운데 버튼 누름 → 닫기 (브라우저처럼)
struct MiddleClickCatcher: NSViewRepresentable {
	let action: () -> Void

	final class CatchView: NSView {
		var action: () -> Void = {}
		private var monitor: Any?

		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
			guard window != nil else { return }
			monitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseUp]) { [weak self] e in
				guard let self, e.buttonNumber == 2, e.window === self.window, !self.isHiddenOrHasHiddenAncestor else { return e }
				let p = self.convert(e.locationInWindow, from: nil)
				if self.bounds.contains(p), self.visibleRect.contains(p) { self.action(); return nil }
				return e
			}
		}

		override func hitTest(_ point: NSPoint) -> NSView? { nil }
	}

	func makeNSView(context: Context) -> CatchView { let v = CatchView(); v.action = action; return v }
	func updateNSView(_ v: CatchView, context: Context) { v.action = action }
	static func dismantleNSView(_ v: CatchView, coordinator: ()) { v.removeFromSuperview() }
}

/// 지금 탭의 웹뷰를 끼워 넣는 칸. 탭·계정을 바꾸면 웹뷰만 바꿔 끼운다 (다른 탭 웹뷰는 살아 있어 페이지·로그인 그대로).
/// SwiftUI 에 탭마다 웹뷰를 opacity 0 으로 두지 않는다 (Ai/iSQL.md 성능 규칙)
struct WebArea: NSViewRepresentable {
	let webView: WKWebView?

	func makeNSView(context: Context) -> NSView { NSView() }

	func updateNSView(_ box: NSView, context: Context) {
		guard box.subviews.first !== webView else { return }
		box.subviews.forEach { $0.removeFromSuperview() }
		guard let webView else { return }
		webView.removeFromSuperview()
		webView.frame = box.bounds
		webView.autoresizingMask = [.width, .height]
		box.addSubview(webView)
	}
}
