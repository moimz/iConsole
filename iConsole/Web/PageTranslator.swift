import Foundation
import AppKit
import WebKit
import Translation
import NaturalLanguage
import Observation

/// 웹 페이지 번역 (애플 Translation 프레임워크, 맥 안에서 번역 — 페이지 글자가 밖으로 나가지 않는다).
/// 페이지의 글자 조각(텍스트 노드)을 모아 번역해 갈아 끼우고, 원문은 기억해 두었다가 다시 누르면 되돌린다.
/// 화면이 계속 바뀌는 페이지(AWS 콘솔 같은 SPA)는 새로 생긴 글자도 이어서 번역한다 (1.2초마다 바뀐 곳만).
///
/// 처음(빌드 25)에는 세션을 SwiftUI .translationTask 안에서만 썼더니 작업이 중간에 취소돼(CancellationError) 번역이 꺼졌다 (사용자).
/// → 원문 언어를 NaturalLanguage 로 알아내고, 언어 파일이 있으면 TranslationSession(installedSource:) 로 세션을 직접 만들어
///   이 객체의 작업에서 번역한다. .translationTask 는 언어 파일이 없을 때 받기 창(prepareTranslation)에만 쓴다.
@Observable @MainActor
final class PageTranslator {
	static let shared = PageTranslator()
	@ObservationIgnored weak var model: AppModel?

	/// 언어 파일 받기 창을 띄울 때만 정한다 (BrowserPane 의 .translationTask)
	var downloadConfiguration: TranslationSession.Configuration?
	@ObservationIgnored private var downloading = false

	/// 번역할 언어 (설정 > 일반 > 번역)
	var target: String = UserDefaults.standard.string(forKey: "translateTo") ?? "ko" {
		didSet { UserDefaults.standard.set(target, forKey: "translateTo") }
	}

	static let targets: [(id: String, label: String)] = [
		("ko", "한국어"), ("en", "English"), ("ja", "日本語"), ("zh-Hans", "中文(简体)"),
	]

	@ObservationIgnored private let world = WKContentWorld.world(name: "iconsole-tr")
	@ObservationIgnored private var sessions: [String: TranslationSession] = [:]
	/// 탭마다 알아낸 원문 언어
	@ObservationIgnored private var sources: [WebTab.ID: Locale.Language] = [:]
	@ObservationIgnored private var loop: Task<Void, Never>?

	/// 번역 버튼: 번역 중이면 원문으로, 아니면 번역 시작
	func toggle(_ tab: WebTab) {
		if tab.translated {
			tab.translated = false
			sources[tab.id] = nil
			Task { await js(tab, "restore") }
			return
		}
		tab.translated = true
		sources[tab.id] = nil
		startLoop()
	}

	private func startLoop() {
		guard loop == nil else { return }
		loop = Task { [weak self] in
			while let self, !Task.isCancelled {
				let tabs = (self.model?.sessions.values.flatMap(\.tabs) ?? []).filter { $0.translated && $0.pending == nil }
				if tabs.isEmpty { break }
				for t in tabs { await self.translateNew(t) }
				try? await Task.sleep(for: .milliseconds(1200))
			}
			self?.loop = nil
		}
	}

	/// 언어 파일 받기 창이 끝나면 (BrowserPane 의 .translationTask 에서)
	func prepare(_ session: TranslationSession) async {
		do { try await session.prepareTranslation() } catch { model?.log("번역 언어 파일 받기: \(error.localizedDescription)") }
		downloading = false
		downloadConfiguration = nil
		startLoop()
	}

	private func translateNew(_ t: WebTab) async {
		guard !t.isLoading, !downloading else { return }
		let tgt = Locale.Language(identifier: target)

		// 1) 원문 언어 (탭마다 한 번): 페이지 글자 앞부분으로 알아낸다
		let src: Locale.Language
		if let s = sources[t.id] {
			src = s
		} else {
			guard let sample = await js(t, "sample") as? String, !sample.isEmpty else { return }
			let r = NLLanguageRecognizer()
			r.processString(sample)
			guard let lang = r.dominantLanguage else { return fail(t, "이 페이지의 언어를 알아내지 못했습니다.") }
			let s = Locale.Language(identifier: lang.rawValue)
			if s.languageCode == tgt.languageCode { return fail(t, "이미 \(Self.name(tgt)) 페이지입니다.") }
			sources[t.id] = s
			src = s
		}

		// 2) 세션: 언어 파일이 있으면 직접, 없으면 받기 창부터
		let key = "\(src.maximalIdentifier)>\(tgt.maximalIdentifier)"
		let session: TranslationSession
		if let s = sessions[key] {
			session = s
		} else {
			switch await LanguageAvailability().status(from: src, to: tgt) {
			case .installed:
				session = TranslationSession(installedSource: src, target: tgt)
				sessions[key] = session
			case .supported:
				downloading = true
				downloadConfiguration = TranslationSession.Configuration(source: src, target: tgt)
				return
			default:
				return fail(t, "\(Self.name(src)) → \(Self.name(tgt)) 번역은 지원하지 않습니다.")
			}
		}

		// 3) 새 글자 조각을 80개씩 번역해 갈아 끼운다
		guard let items = await js(t, "collect", max: 1500) as? [[String: Any]], !items.isEmpty else { return }
		var requests: [TranslationSession.Request] = []
		for it in items {
			guard let id = it["id"] as? Int, let text = it["text"] as? String else { continue }
			requests.append(TranslationSession.Request(sourceText: text, clientIdentifier: String(id)))
		}
		var i = 0
		while i < requests.count {
			let chunk = Array(requests[i..<min(i + 80, requests.count)])
			i += 80
			do {
				let res = try await session.translations(from: chunk)
				let out: [[String: Any]] = res.compactMap { r in
					guard let id = r.clientIdentifier.flatMap(Int.init) else { return nil }
					return ["id": id, "text": r.targetText]
				}
				await js(t, "apply", items: out)
			} catch is CancellationError {
				// 취소는 실패가 아니다: 못 한 조각은 다음 차례에 다시
				await js(t, "forget", items: requests[(i - 80)...].compactMap { $0.clientIdentifier.flatMap(Int.init) }.map { ["id": $0] })
				return
			} catch {
				sessions[key] = nil
				return fail(t, error.localizedDescription)
			}
		}
	}

	/// 번역을 끄고 원문으로 되돌린 뒤 알린다
	private func fail(_ t: WebTab, _ message: String) {
		t.translated = false
		sources[t.id] = nil
		Task { await js(t, "restore") }
		model?.log("번역 못 함: \(message)")
		let a = NSAlert()
		a.messageText = "이 페이지를 번역하지 못했습니다"
		a.informativeText = message
		a.runModal()
	}

	private static func name(_ l: Locale.Language) -> String {
		Locale(identifier: "ko").localizedString(forLanguageCode: l.languageCode?.identifier ?? "") ?? l.minimalIdentifier
	}

	@discardableResult
	private func js(_ t: WebTab, _ op: String, items: [[String: Any]] = [], max: Int = 0) async -> Any? {
		try? await t.webView.callAsyncJavaScript(Self.script, arguments: ["op": op, "items": items, "max": max], in: nil, contentWorld: world)
	}

	/// 페이지 쪽 (iconsole-tr 세계). 인자: op, items, max
	/// sample: 언어를 알아낼 글자 앞부분 / collect: 아직 안 한 글자 조각 [{id, text}] (코드 · 입력칸 · translate="no" · notranslate 빼고, 바뀐 게 없으면 [])
	/// apply: [{id, text}] 로 바꾼다 (앞뒤 빈칸은 원문 그대로) / forget: [{id}] 를 다음에 다시 모으게 / restore: 원문으로, 지켜보기 멈춤
	static let script = #"""
	const W = window;
	if (op === 'sample') return (document.body ? document.body.innerText : '').slice(0, 4000);
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
	if (op === 'forget') {
	  for (const it of items) { const n = st.nodes[it.id]; if (n) st.done.delete(n); }
	  st.dirty = true;
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
