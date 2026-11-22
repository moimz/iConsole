import Foundation

/// MCP 도구 설명과 페이지에 넣는 스크립트 (스크립트는 페이지 스크립트와 떨어진 iconsole-mcp 세계에서 돈다)
enum MCPTools {
	static let instructions = """
	iConsole 은 AWS · 구글 · 애플 개발자 콘솔 계정마다 로그인된 웹뷰(탭)를 가진 맥 앱이다. 로그인은 이미 되어 있다.
	1) list_accounts 로 쓸 수 있는 계정과 권한을 본다. 2) open_tab 으로 콘솔 페이지를 열거나 list_tabs · select_tab 으로 이미 열린 탭을 고른다.
	3) read_page 로 페이지 글자와 누를 수 있는 것 · 입력칸의 번호(ref)를 읽는다. 4) click · fill · select_option 은 그 ref 로 한다.
	페이지가 바뀌면 ref 도 바뀌니 다시 read_page 한다. 설정을 바꾸기 전에는 무엇을 어떻게 바꿀지 사용자에게 먼저 말한다.
	로그인 페이지는 읽을 수도 다룰 수도 없다(사용자가 iConsole 에서 직접 로그인). 암호 칸에는 입력할 수 없다.
	"""

	private static let accountArg: [String: Any] = ["type": "string", "description": "계정 이름 또는 id (list_accounts). 빼면 iConsole 에서 지금 보고 있는 계정"]
	private static let tabArg: [String: Any] = ["type": "string", "description": "탭 id (list_tabs). 빼면 그 계정의 지금 탭"]

	static let list: [[String: Any]] = [
		["name": "list_accounts",
		 "description": "MCP 에 열린 계정 목록(이름 · 서비스 · 그룹 · 열린 탭 수 · 즐겨찾기)과 지금 설정(접근 범위 · 권한). 암호 · OTP 는 주지 않는다",
		 "inputSchema": ["type": "object", "properties": [String: Any]()]],
		["name": "list_tabs",
		 "description": "계정의 열린 탭 (id · 제목 · 주소 · 지금 탭인지)",
		 "inputSchema": ["type": "object", "properties": ["account": accountArg]]],
		["name": "open_tab",
		 "description": "계정에서 주소를 연다 (기본은 새 탭, tab 을 주면 그 탭에서). iConsole 화면도 그 계정 · 탭으로 바뀐다. 다 읽을 때까지 기다린 뒤 제목 · 주소를 돌려준다",
		 "inputSchema": ["type": "object", "properties": [
		 	"account": accountArg,
		 	"url": ["type": "string", "description": "예: https://console.cloud.google.com/apis/credentials"],
		 	"tab": ["type": "string", "description": "이 탭에서 열기 (빼면 새 탭)"],
		 ], "required": ["url"]]],
		["name": "select_tab",
		 "description": "그 탭을 iConsole 에서 앞으로 (되살린 탭이면 이때 읽는다)",
		 "inputSchema": ["type": "object", "properties": ["account": accountArg, "tab": tabArg], "required": ["tab"]]],
		["name": "read_page",
		 "description": "페이지 글자와, 누를 수 있는 것 · 입력칸 목록을 [번호] 와 함께 돌려준다 (click · fill · select_option 에 쓰는 ref). 입력칸은 지금 값도 보이되 암호 칸 값은 숨긴다. 로그인 페이지는 안 된다",
		 "inputSchema": ["type": "object", "properties": [
		 	"account": accountArg, "tab": tabArg,
		 	"max_chars": ["type": "integer", "description": "페이지 글자 최대 (기본 20000)"],
		 ]]],
		["name": "screenshot",
		 "description": "탭 화면을 PNG 로 (그 계정 · 탭을 iConsole 앞으로 가져와 찍는다). 글자는 read_page 가 더 정확하다",
		 "inputSchema": ["type": "object", "properties": ["account": accountArg, "tab": tabArg]]],
		["name": "click",
		 "description": "read_page 의 [ref] 요소를 누른다. 권한이 '확인 후 실행' 이면 사용자가 iConsole 에서 허용해야 한다",
		 "inputSchema": ["type": "object", "properties": ["account": accountArg, "tab": tabArg, "ref": ["type": "integer"]], "required": ["ref"]]],
		["name": "fill",
		 "description": "read_page 의 [ref] 입력칸 값을 바꾼다 (원래 값은 지우고). 암호 칸은 안 된다. 권한이 '확인 후 실행' 이면 사용자가 허용해야 한다",
		 "inputSchema": ["type": "object", "properties": ["account": accountArg, "tab": tabArg, "ref": ["type": "integer"], "value": ["type": "string"]], "required": ["ref", "value"]]],
		["name": "select_option",
		 "description": "read_page 의 [ref] <select> 에서 항목을 고른다 (value 는 항목 값 또는 보이는 글자). 펼침 메뉴처럼 select 가 아닌 것은 click 으로 펼친 뒤 항목을 click",
		 "inputSchema": ["type": "object", "properties": ["account": accountArg, "tab": tabArg, "ref": ["type": "integer"], "value": ["type": "string"]], "required": ["ref", "value"]]],
		["name": "wait",
		 "description": "기다린다 (최대 15초). text 를 주면 페이지에 그 글자가 나올 때까지",
		 "inputSchema": ["type": "object", "properties": [
		 	"account": accountArg, "tab": tabArg,
		 	"seconds": ["type": "number", "description": "기본 2"],
		 	"text": ["type": "string"],
		 ]]],
	]

	/// 페이지 글자 + 누를 수 있는 것 · 입력칸에 번호(data-iconsole-ref)를 매겨 목록으로. 인자: maxChars
	static let snapshot = #"""
	const SEL = 'a[href],button,input:not([type=hidden]),select,textarea,summary,[role=button],[role=link],[role=tab],[role=checkbox],[role=radio],[role=menuitem],[role=option],[role=switch],[role=combobox],[contenteditable=""],[contenteditable=true]';
	document.querySelectorAll('[data-iconsole-ref]').forEach(e => e.removeAttribute('data-iconsole-ref'));
	const clean = s => (s || '').replace(/\s+/g, ' ').trim();
	const vis = e => { const r = e.getBoundingClientRect(); if (r.width < 1 || r.height < 1) return false; const s = getComputedStyle(e); return s.visibility !== 'hidden' && s.display !== 'none'; };
	const name = e => clean(e.getAttribute('aria-label') || (e.labels && e.labels.length ? e.labels[0].innerText : '') || e.getAttribute('placeholder') || e.getAttribute('title') || (e.tagName === 'INPUT' ? '' : e.innerText) || e.getAttribute('name') || '').slice(0, 100);
	let n = 0; const lines = [];
	for (const e of document.querySelectorAll(SEL)) {
	  if (n >= 400 || !vis(e)) continue;
	  n++; e.setAttribute('data-iconsole-ref', String(n));
	  const tag = e.tagName.toLowerCase(), role = e.getAttribute('role'), type = e.type ? String(e.type).toLowerCase() : '';
	  const kind = role || (tag === 'input' ? 'input:' + type : tag);
	  let extra = '';
	  if (tag === 'input' || tag === 'textarea') {
	    if (type === 'password') extra = ' (암호 칸, 값 숨김)';
	    else if (type === 'checkbox' || type === 'radio') extra = e.checked ? ' [x]' : ' [ ]';
	    else extra = ' value="' + clean(e.value).slice(0, 300) + '"';
	  } else if (tag === 'select') {
	    const cur = e.options[e.selectedIndex];
	    extra = ' value="' + clean(cur ? cur.text : '') + '" options=' + JSON.stringify([...e.options].slice(0, 40).map(o => clean(o.text)));
	  } else if (tag === 'a') {
	    extra = ' → ' + (e.getAttribute('href') || '').slice(0, 150);
	  }
	  if (e.getAttribute('aria-checked') === 'true' || e.getAttribute('aria-selected') === 'true') extra += ' (선택됨)';
	  if (e.getAttribute('aria-expanded')) extra += e.getAttribute('aria-expanded') === 'true' ? ' (펼침)' : ' (접힘)';
	  if (e.disabled || e.getAttribute('aria-disabled') === 'true') extra += ' (꺼짐)';
	  lines.push('[' + n + '] ' + kind + ' "' + name(e) + '"' + extra);
	}
	let text = (document.body ? document.body.innerText : '').replace(/[ \t]+/g, ' ').replace(/\n\s*\n\s*\n+/g, '\n\n').trim();
	if (text.length > maxChars) text = text.slice(0, maxChars) + '\n… (글자 ' + text.length + '자 중 ' + maxChars + '자까지)';
	return '## 페이지 글자\n' + text + '\n\n## 누를 수 있는 것 · 입력칸 (ref)\n' + lines.join('\n');
	"""#

	/// [ref] 요소 한 줄 설명 (확인 창에 보인다). 암호 칸이면 "password". 인자: ref
	static let describe = #"""
	const e = document.querySelector('[data-iconsole-ref="' + ref + '"]');
	if (!e) return '';
	if (e.type && String(e.type).toLowerCase() === 'password') return 'password';
	const clean = s => (s || '').replace(/\s+/g, ' ').trim();
	const nm = clean(e.getAttribute('aria-label') || (e.labels && e.labels.length ? e.labels[0].innerText : '') || e.getAttribute('placeholder') || (e.tagName === 'INPUT' ? '' : e.innerText) || e.getAttribute('name') || '').slice(0, 100);
	return '[' + ref + '] ' + (e.getAttribute('role') || e.tagName.toLowerCase()) + ' "' + nm + '"';
	"""#

	/// 누르기 · 입력 · 고르기. 인자: ref, op(click/fill/select_option), value
	static let act = #"""
	const e = document.querySelector('[data-iconsole-ref="' + ref + '"]');
	if (!e) throw new Error('[' + ref + '] 요소가 없습니다. read_page 를 다시 하세요');
	e.scrollIntoView({block: 'center'});
	if (op === 'click') {
	  if (e.focus) e.focus();
	  e.click();
	  return '눌렀습니다';
	}
	if (op === 'fill') {
	  if (e.type && String(e.type).toLowerCase() === 'password') throw new Error('암호 칸에는 입력하지 않습니다');
	  e.focus();
	  if (e.isContentEditable) {
	    e.innerText = value;
	  } else {
	    const proto = e.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
	    Object.getOwnPropertyDescriptor(proto, 'value').set.call(e, value);
	  }
	  e.dispatchEvent(new Event('input', {bubbles: true}));
	  e.dispatchEvent(new Event('change', {bubbles: true}));
	  return '입력했습니다';
	}
	if (op === 'select_option') {
	  if (e.tagName !== 'SELECT') throw new Error('select 가 아닙니다. click 으로 펼친 뒤 항목을 누르세요');
	  const o = [...e.options].find(o => o.value === value || o.text.trim() === value);
	  if (!o) throw new Error('없는 항목: ' + value);
	  e.value = o.value;
	  e.dispatchEvent(new Event('change', {bubbles: true}));
	  return '골랐습니다: ' + o.text.trim();
	}
	throw new Error('모르는 동작: ' + op);
	"""#
}
