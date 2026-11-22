import Foundation
import AppKit
import WebKit
import Translation
import NaturalLanguage
import Observation

/// 웹 페이지 번역 (애플 Translation 프레임워크, 맥 안에서 번역 — 페이지 글자가 밖으로 나가지 않는다).
/// 페이지의 글자 조각(텍스트 노드)을 모아 번역해 갈아 끼우고, 원문은 기억해 두었다가 다시 누르면 되돌린다.
/// 화면이 계속 바뀌는 페이지(AWS 콘솔 같은 SPA)는 새로 생긴 글자도 이어서 번역한다 (0.6초마다 바뀐 곳만).
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
	/// 받기 창을 한 번 띄운 언어 쌍 (거절하면 다시 묻지 않는다)
	@ObservationIgnored private var askedDownload: Set<String> = []

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
	/// 번역해 본 글자 (언어 쌍마다, 앱이 켜져 있는 동안). 화면이 다시 그려져 같은 글자가 또 나오면 바로 넣는다
	@ObservationIgnored private var memory: [String: [String: String]] = [:]

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
				try? await Task.sleep(for: .milliseconds(600))
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

		// 2) 세션. 번역 엔진은 빠른 방식(lowLatency)과 정확한 방식(highFidelity) 이 있고, 정확한 방식은 조각 하나에 0.2초쯤 걸려
		//    페이지가 Safari 보다 한참 느리게 바뀌었다 (명령줄로 재 봄: 100개 22초). → 빠른 방식을 먼저 쓰고,
		//    그 언어 파일이 없으면 한 번 받기 창을 띄우되, 받는 동안에는 설치된 정확한 방식으로 번역한다
		let key = "\(src.maximalIdentifier)>\(tgt.maximalIdentifier)"
		let fastKey = "fast \(src.maximalIdentifier)>\(tgt.maximalIdentifier)"
		let slowKey = "slow \(src.maximalIdentifier)>\(tgt.maximalIdentifier)"
		var session: TranslationSession? = sessions[fastKey]
		if session == nil, #available(macOS 26.4, *) {
			let fast = TranslationSession.Strategy.lowLatency
			switch await LanguageAvailability(preferredStrategy: fast).status(from: src, to: tgt) {
			case .installed:
				session = TranslationSession(installedSource: src, target: tgt, preferredStrategy: fast)
				sessions[fastKey] = session
			case .supported where !askedDownload.contains(fastKey):
				askedDownload.insert(fastKey)
				downloading = true
				downloadConfiguration = TranslationSession.Configuration(source: src, target: tgt, preferredStrategy: fast)
				return
			default:
				break
			}
		}
		if session == nil {
			if let s = sessions[slowKey] {
				session = s
			} else {
				switch await LanguageAvailability().status(from: src, to: tgt) {
				case .installed:
					session = TranslationSession(installedSource: src, target: tgt)
					sessions[slowKey] = session
				case .supported where !askedDownload.contains(slowKey):
					askedDownload.insert(slowKey)
					downloading = true
					downloadConfiguration = TranslationSession.Configuration(source: src, target: tgt)
					return
				case .supported:
					return fail(t, "\(Self.name(src)) → \(Self.name(tgt)) 번역 언어 파일을 받지 못했습니다.")
				default:
					return fail(t, "\(Self.name(src)) → \(Self.name(tgt)) 번역은 지원하지 않습니다.")
				}
			}
		}
		guard let session else { return }

		// 3) 새 글자 조각: 이미 번역해 본 글자는 바로 넣고, 나머지는 같은 글자끼리 묶어 한 번만 보낸다.
		//    일괄 번역(translate(batch:))은 끝나는 대로 하나씩 오니 모이는 대로(20개 또는 0.1초) 바로 페이지에 넣는다.
		//    (빌드 26 은 80개씩 묶음을 차례로 보내고 묶음이 끝나야 넣어 Safari 보다 한참 느렸다, 사용자)
		guard let items = await js(t, "collect", max: 3000) as? [[String: Any]], !items.isEmpty else { return }
		var known: [[String: Any]] = []
		var ids: [String: [Int]] = [:]
		var order: [String] = []
		for it in items {
			guard let id = it["id"] as? Int, let text = it["text"] as? String else { continue }
			if let done = memory[key]?[text] { known.append(["id": id, "text": done]); continue }
			if ids[text] == nil { order.append(text) }
			ids[text, default: []].append(id)
		}
		if !known.isEmpty { await js(t, "apply", items: known) }
		guard !order.isEmpty else { return }
		let requests = order.enumerated().map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset)) }
		var buffer: [[String: Any]] = []
		var last = Date()
		var finished = Set<Int>()
		do {
			for try await r in session.translate(batch: requests) {
				guard let k = r.clientIdentifier.flatMap(Int.init) else { continue }
				finished.insert(k)
				let src = order[k]
				memory[key, default: [:]][src] = r.targetText
				for id in ids[src] ?? [] { buffer.append(["id": id, "text": r.targetText]) }
				if buffer.count >= 20 || Date().timeIntervalSince(last) > 0.1 {
					await js(t, "apply", items: buffer)
					buffer.removeAll()
					last = Date()
				}
			}
			if !buffer.isEmpty { await js(t, "apply", items: buffer) }
		} catch is CancellationError {
			// 취소는 실패가 아니다: 받은 것은 넣고, 못 한 조각은 다음 차례에 다시
			if !buffer.isEmpty { await js(t, "apply", items: buffer) }
			let left = order.indices.filter { !finished.contains($0) }.flatMap { ids[order[$0]] ?? [] }
			await js(t, "forget", items: left.map { ["id": $0] })
		} catch {
			sessions[fastKey] = nil
			sessions[slowKey] = nil
			return fail(t, error.localizedDescription)
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
	// 지금 화면에 보이는 글자부터 (Safari 처럼 보이는 곳이 먼저 바뀌게)
	const H = innerHeight;
	const seen = [], rest = [];
	let n;
	while ((seen.length + rest.length) < max && (n = walker.nextNode())) {
	  st.done.add(n);
	  const id = st.nodes.push(n) - 1;
	  const r = n.parentElement.getBoundingClientRect();
	  ((r.bottom > -50 && r.top < H + 200 && r.width > 0) ? seen : rest).push({id: id, text: n.nodeValue.trim()});
	}
	if ((seen.length + rest.length) >= max) st.dirty = true;
	return seen.concat(rest);
	"""#
}
