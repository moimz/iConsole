import AppKit
import WebKit
import Observation

/// 페이지 안 찾기 (⌘F · ⌘G · ⇧⌘G · ⌘E). 찾기 줄(FindBar)이 이걸 본다.
/// WKWebView.find 는 고른 글자(회색)로만 보이고 개수를 모른다 → 페이지 안에서 글자를 모아 찾고
/// CSS Custom Highlight 로 모두 노랗게, 지금 것은 주황으로 칠한다 (Safari 처럼 "3/12")
@Observable @MainActor
final class PageFinder {
	static let shared = PageFinder()
	@ObservationIgnored weak var model: AppModel?

	var shown = false
	var text = "" { didSet { if text != oldValue { search() } } }
	private(set) var count = 0
	private(set) var index = 0
	/// 찾기 칸에 포커스 주기 (값이 바뀔 때마다)
	private(set) var focus = 0

	/// 페이지 스크립트와 따로 떨어진 세계 (페이지가 우리 변수를 보거나 덮지 못하게)
	private let world = WKContentWorld.world(name: "icfind")
	@ObservationIgnored private weak var painted: WKWebView?
	@ObservationIgnored private var generation = 0

	private var webView: WKWebView? { model?.current?.active?.webView }

	func show() {
		// 맥 공용 찾기 클립보드에서 채우지 않는다 — 다른 앱에서 찾은 말(사용자: "Permute")이 들어와 헷갈린다. 이 앱에서 찾던 말은 그대로 남는다
		shown = true
		focus += 1
		search()
	}

	func hide() {
		shown = false
		clear()
	}

	/// ⌘G (1) · ⇧⌘G (-1). 찾기 줄이 닫혀 있으면 열고 찾는다
	func step(_ d: Int) {
		if !shown { show() }
		guard !text.isEmpty else { return }
		run("step", d)
	}

	/// ⌘E: 고른 글자로 찾기
	func useSelection() {
		guard let w = webView else { return }
		Task {
			let s = (try? await w.callAsyncJavaScript("return String(getSelection() || '')", contentWorld: world)) as? String ?? ""
			let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !t.isEmpty else { return }
			text = String(t.prefix(200))
			if !shown { shown = true }
		}
	}

	/// 글자가 바뀌었거나 탭·페이지가 바뀌었을 때
	func search() {
		guard shown else { return }
		if let p = painted, p !== webView { Task { _ = try? await p.callAsyncJavaScript(Self.clearJS, contentWorld: world) } }
		guard !text.isEmpty else { clear(); return }
		run("find", 0)
	}

	private func clear() {
		count = 0; index = 0
		generation += 1
		for w in [painted, webView].compactMap({ $0 }) {
			Task { _ = try? await w.callAsyncJavaScript(Self.clearJS, contentWorld: world) }
		}
		painted = nil
	}

	private func run(_ op: String, _ d: Int) {
		guard let w = webView else { count = 0; index = 0; return }
		generation += 1
		let g = generation
		painted = w
		Task {
			let r = try? await w.callAsyncJavaScript(Self.js, arguments: ["op": op, "q": text, "d": d], contentWorld: world) as? [String: Any]
			guard g == generation else { return }
			count = (r?["count"] as? Int) ?? 0
			index = (r?["index"] as? Int) ?? 0
		}
	}

	private static let clearJS = "if (window.CSS && CSS.highlights) { CSS.highlights.delete('icfind'); CSS.highlights.delete('icfind-cur'); }"

	/// op: find (처음부터, 화면에 보이는 것 다음 것을 지금 것으로) · step (d 만큼 옮김, 그 사이 페이지가 바뀌었으면 다시 모음)
	private static let js = #"""
	const MAX = 1000;
	if (!window.CSS || !CSS.highlights || typeof Highlight === 'undefined') return {count: 0, index: 0};
	if (!document.getElementById('icfind-style')) {
		const st = document.createElement('style');
		st.id = 'icfind-style';
		st.textContent = '::highlight(icfind){background-color:rgba(255,214,0,.45);color:inherit}' +
			'::highlight(icfind-cur){background-color:#ff9f0a;color:#000}';
		(document.head || document.documentElement).appendChild(st);
	}
	// 글자가 아닌 것 (코드 · 스타일 · 입력칸). SVG 안 요소는 tagName 이 소문자라 대문자로 바꿔 본다
	const SKIP = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'TEXTAREA', 'SELECT', 'OPTION', 'TITLE', 'DESC', 'IFRAME', 'OBJECT']);
	// 보이는 글자만: 숨김(display · visibility · 투명), 화면 읽기 프로그램용으로 1px 로 잘라 둔 글자는 뺀다
	const seen = new Map();
	const visible = (el) => {
		if (!el) return false;
		if (seen.has(el)) return seen.get(el);
		let ok = el.checkVisibility ? el.checkVisibility({visibilityProperty: true, opacityProperty: true}) : true;
		if (ok) { const b = el.getBoundingClientRect(); if (b.width <= 1 && b.height <= 1) ok = false; }
		seen.set(el, ok);
		return ok;
	};
	// 글자 조각을 모두 이어 붙여 찾는다 (<b> 로 나뉜 낱말도 찾게). 열린 shadow DOM 안도 본다
	const collect = () => {
		const nodes = [], starts = [];
		let all = '';
		const walk = (root) => {
			const tw = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
				acceptNode: (n) => n.nodeType === 1 && SKIP.has(n.tagName.toUpperCase()) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT
			});
			for (let n = tw.currentNode; n; n = tw.nextNode()) {
				if (n.nodeType === 3) { starts.push(all.length); nodes.push(n); all += n.data; }
				else if (n.shadowRoot) walk(n.shadowRoot);
			}
		};
		if (document.body) walk(document.body);
		return {nodes, starts, all};
	};
	const locate = (c, pos) => {
		let lo = 0, hi = c.starts.length - 1;
		while (lo < hi) { const m = (lo + hi + 1) >> 1; if (c.starts[m] <= pos) lo = m; else hi = m - 1; }
		return [c.nodes[lo], pos - c.starts[lo]];
	};
	const gather = (q) => {
		const c = collect(), hay = c.all.toLocaleLowerCase(), needle = q.toLocaleLowerCase(), out = [];
		if (!needle || hay.length !== c.all.length) {
			// 소문자로 바꾸며 길이가 바뀌는 글자가 있으면 (드묾) 대소문자 구분해서
			if (needle) for (let i = c.all.indexOf(q); i >= 0 && out.length < MAX; i = c.all.indexOf(q, i + q.length)) out.push(i);
		} else {
			for (let i = hay.indexOf(needle); i >= 0 && out.length < MAX; i = hay.indexOf(needle, i + needle.length)) out.push(i);
		}
		const ranges = [];
		for (const i of out) {
			const [sn, so] = locate(c, i), [en, eo] = locate(c, i + q.length - 1);
			const r = document.createRange();
			try { r.setStart(sn, so); r.setEnd(en, eo + 1); } catch (e) { continue; }
			// 안 보이는 것(display:none 등)은 뺀다
			if (r.getClientRects().length === 0 || !visible(r.startContainer.parentElement)) continue;
			ranges.push(r);
		}
		return ranges;
	};
	const reveal = (r) => {
		const el = r.startContainer.parentElement;
		let b = r.getBoundingClientRect();
		const H = innerHeight, W = innerWidth;
		if (b.top < 0 || b.bottom > H || b.left < 0 || b.right > W) {
			// 안쪽 스크롤 칸에 있을 수 있어 요소부터 보이게 한 뒤, 찾은 글자를 화면 가운데쯤으로
			if (el) el.scrollIntoView({block: 'nearest', inline: 'nearest'});
			b = r.getBoundingClientRect();
			if (b.top < 0 || b.bottom > H) scrollBy(0, b.top - H / 2);
		}
	};
	const paint = (ranges, cur) => {
		CSS.highlights.set('icfind', new Highlight(...ranges));
		if (ranges.length) {
			const r = ranges[cur];
			CSS.highlights.set('icfind-cur', new Highlight(r));
			reveal(r);
		} else CSS.highlights.delete('icfind-cur');
		return {count: ranges.length, index: ranges.length ? cur + 1 : 0};
	};
	// 이 세계의 전역 변수는 부를 때마다 새로 생긴다 (WebKit callAsyncJavaScript, 2026-11-27 확인) →
	// 찾은 것 · 지금 것은 문서에 남는 CSS.highlights 에서, 찾는 말은 style 요소에 둔다
	const st = document.getElementById('icfind-style');
	const prev = CSS.highlights.get('icfind'), curH = CSS.highlights.get('icfind-cur');
	let ranges = prev && st.dataset.q === q ? [...prev] : null;
	let cur = ranges && curH ? ranges.indexOf([...curH][0]) : -1;
	if (op === 'find' || !ranges || cur < 0) {
		st.dataset.q = q;
		ranges = gather(q);
		// 화면 맨 위 아래로 처음 나오는 것부터 (Safari 처럼 지금 보는 곳 근처)
		cur = Math.max(0, ranges.findIndex(r => r.getBoundingClientRect().bottom >= 0));
		return paint(ranges, cur);
	}
	// 그 사이 페이지가 바뀌어 지금 것이 문서에서 떨어졌으면 다시 모은다
	if (!ranges[cur].startContainer.isConnected) {
		ranges = gather(q);
		cur = 0;
		if (!ranges.length) return paint(ranges, 0);
	}
	const n = ranges.length;
	cur = ((cur + d) % n + n) % n;
	return paint(ranges, cur);
	"""#
}
