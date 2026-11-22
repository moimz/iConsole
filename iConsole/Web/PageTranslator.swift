import Foundation
import WebKit
import Translation
import Observation

/// 웹 페이지 번역 (애플 Translation 프레임워크, 맥 안에서 번역 — 페이지 글자가 밖으로 나가지 않는다).
/// 페이지의 글자 조각(텍스트 노드)을 모아 번역해 갈아 끼우고, 원문은 기억해 두었다가 다시 누르면 되돌린다.
/// 화면이 계속 바뀌는 페이지(AWS 콘솔 같은 SPA)는 새로 생긴 글자도 이어서 번역한다 (1.2초마다 바뀐 곳만).
/// 세션은 SwiftUI .translationTask 로만 받을 수 있어서 BrowserPane 이 이 객체의 configuration 으로 붙인다
@Observable @MainActor
final class PageTranslator {
	static let shared = PageTranslator()
	@ObservationIgnored weak var model: AppModel?

	/// 바뀌면(또는 invalidate) .translationTask 가 다시 돈다
	var configuration: TranslationSession.Configuration?

	/// 번역할 언어 (설정 > 일반 > 번역)
	var target: String = UserDefaults.standard.string(forKey: "translateTo") ?? "ko" {
		didSet {
			UserDefaults.standard.set(target, forKey: "translateTo")
			if configuration != nil { configuration = Self.config(target) }
		}
	}

	static let targets: [(id: String, label: String)] = [
		("ko", "한국어"), ("en", "English"), ("ja", "日本語"), ("zh-Hans", "中文(简体)"),
	]

	@ObservationIgnored private let world = WKContentWorld.world(name: "iconsole-tr")

	private static func config(_ target: String) -> TranslationSession.Configuration {
		TranslationSession.Configuration(source: nil, target: Locale.Language(identifier: target))
	}

	/// 번역 버튼: 번역 중이면 원문으로, 아니면 번역 시작
	func toggle(_ tab: WebTab) {
		if tab.translated {
			tab.translated = false
			Task { _ = try? await tab.webView.callAsyncJavaScript(Self.script, arguments: ["op": "restore", "items": [Any](), "max": 0], in: nil, contentWorld: world) }
			return
		}
		tab.translated = true
		if configuration == nil { configuration = Self.config(target) } else { configuration?.invalidate() }
	}

	/// .translationTask 안에서: 지금 계정의 번역 중인 탭들을 새 글자가 생길 때마다 번역한다 (번역 중인 탭이 없으면 끝)
	func run(_ session: TranslationSession) async {
		while !Task.isCancelled {
			let tabs = model?.current?.tabs.filter { $0.translated && $0.pending == nil } ?? []
			if tabs.isEmpty { return }
			for t in tabs where !Task.isCancelled { await translateNew(t, session) }
			try? await Task.sleep(for: .milliseconds(1200))
		}
	}

	private func translateNew(_ t: WebTab, _ session: TranslationSession) async {
		guard !t.isLoading,
		      let raw = try? await t.webView.callAsyncJavaScript(Self.script, arguments: ["op": "collect", "items": [Any](), "max": 1500], in: nil, contentWorld: world),
		      let items = raw as? [[String: Any]], !items.isEmpty else { return }
		var chunk: [TranslationSession.Request] = []
		func flush() async -> Bool {
			defer { chunk.removeAll() }
			guard !chunk.isEmpty else { return true }
			do {
				let res = try await session.translations(from: chunk)
				let out: [[String: Any]] = res.compactMap { r in
					guard let id = r.clientIdentifier.flatMap(Int.init) else { return nil }
					return ["id": id, "text": r.targetText]
				}
				_ = try? await t.webView.callAsyncJavaScript(Self.script, arguments: ["op": "apply", "items": out, "max": 0], in: nil, contentWorld: world)
				return true
			} catch {
				// 이미 그 언어인 페이지, 받지 않은 언어, 알아내지 못한 언어 등 → 번역을 끄고 알린다
				t.translated = false
				_ = try? await t.webView.callAsyncJavaScript(Self.script, arguments: ["op": "restore", "items": [Any](), "max": 0], in: nil, contentWorld: world)
				model?.log("번역 못 함: \(error.localizedDescription)")
				let a = NSAlert()
				a.messageText = "이 페이지를 번역하지 못했습니다"
				a.informativeText = error.localizedDescription
				a.runModal()
				return false
			}
		}
		for it in items {
			guard let id = it["id"] as? Int, let text = it["text"] as? String else { continue }
			chunk.append(TranslationSession.Request(sourceText: text, clientIdentifier: String(id)))
			if chunk.count >= 80, !(await flush()) { return }
		}
		_ = await flush()
	}

	/// 페이지 쪽 (iconsole-tr 세계). 인자: op(collect / apply / restore), items, max
	/// collect: 아직 안 한 글자 조각을 [{id, text}] 로 (코드 · 입력칸 · translate="no" · notranslate 는 빼고), 바뀐 게 없으면 []
	/// apply: [{id, text}] 로 바꾼다 (앞뒤 빈칸은 원문 그대로). restore: 원문으로 되돌리고 지켜보기를 멈춘다
	static let script = #"""
	const W = window;
	if (op === 'restore') {
	  const st = W.__icTr;
	  if (st) { for (const [n, v] of st.orig) n.nodeValue = v; st.obs.disconnect(); delete W.__icTr; }
	  return true;
	}
	if (!W.__icTr) {
	  const s = { nodes: [], done: new WeakSet(), orig: new Map(), dirty: true };
	  // 내가 바꾼 글자(orig 에 있는 노드의 characterData)는 바뀜으로 치지 않는다
	  s.obs = new MutationObserver(recs => {
	    if (recs.some(r => r.type !== 'characterData' || !s.orig.has(r.target))) s.dirty = true;
	  });
	  s.obs.observe(document.documentElement, {subtree: true, childList: true, characterData: true});
	  W.__icTr = s;
	}
	const st = W.__icTr;
	if (op === 'apply') {
	  for (const it of items) {
	    const n = st.nodes[it.id];
	    if (!n) continue;
	    const v = n.nodeValue;
	    if (!st.orig.has(n)) st.orig.set(n, v);
	    n.nodeValue = v.match(/^\s*/)[0] + it.text + v.match(/\s*$/)[0];
	  }
	  return true;
	}
	if (!st.dirty) return [];
	st.dirty = false;
	const SKIP = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'CODE', 'PRE', 'KBD', 'SAMP', 'TEXTAREA', 'INPUT', 'SELECT', 'OPTION', 'SVG', 'TEMPLATE']);
	const out = [];
	const root = document.body || document.documentElement;
	const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, { acceptNode(n) {
	  if (st.done.has(n)) return NodeFilter.FILTER_REJECT;
	  const t = n.nodeValue;
	  if (!t || t.trim().length < 2 || !/\p{L}/u.test(t)) return NodeFilter.FILTER_REJECT;
	  for (let e = n.parentElement; e && e !== root; e = e.parentElement) {
	    if (SKIP.has(e.tagName) || e.isContentEditable || e.getAttribute('translate') === 'no' || e.classList.contains('notranslate')) return NodeFilter.FILTER_REJECT;
	  }
	  return NodeFilter.FILTER_ACCEPT;
	}});
	let n;
	while (out.length < max && (n = walker.nextNode())) {
	  st.done.add(n);
	  const id = st.nodes.push(n) - 1;
	  out.push({id: id, text: n.nodeValue.trim()});
	}
	if (out.length >= max) st.dirty = true;
	return out;
	"""#
}
