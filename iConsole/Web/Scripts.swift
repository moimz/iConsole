import Foundation

/// 웹뷰에 넣는 스크립트
enum Scripts {
	// 로그인 페이지 채우기. 앱과는 iconsole 세계에서만 이야기해서 페이지 스크립트는 값을 달라고 할 수 없다.
	// 아마존 루트 로그인: 루트 사용자 고르기 → 이메일 → (CAPTCHA 는 직접) → 암호 → MFA 코드
	static let filler = #"""
	(async function(){
	  const ask = m => window.webkit.messageHandlers.icfill.postMessage(m);
	  const cfg = await ask({op:'hello'});
	  if (!cfg) return;
	  const log = t => ask({op:'log', text:t});
	  // 보이는 칸만 (구글 아이디 화면의 숨은 암호 칸 hiddenPassword 같은 것은 빼고)
	  const shown = e => {
	    if (!e || e.disabled || e.readOnly || e.closest('[aria-hidden=true]') || /hidden/i.test(e.name || '')) return false;
	    const r = e.getBoundingClientRect();
	    return r.width > 20 && r.height > 10;
	  };
	  const all = s => [...document.querySelectorAll(s)];
	  // 칸 설명: id · name · placeholder · aria-label · 이어진 label 글자
	  const desc = e => [e.id, e.name, e.placeholder, e.getAttribute('aria-label'), e.getAttribute('autocomplete'),
	    ...[...(e.labels || [])].map(l => l.textContent),
	    ...(e.getAttribute('aria-labelledby') || '').split(/\s+/).map(id => document.getElementById(id)?.textContent || '')].join(' ');
	  const codeHint = /mfa|otp|one.?time|totp|2fa|verification.?code|security.?code|auth\w*.?code|enter.?code|인증.?코드|보안.?코드|확인.?코드/i;
	  const done = new WeakSet();
	  // React 입력칸(새 AWS 로그인의 awsui_input 등)은 e.value = v 를 모른 채 다시 빈 값으로 그린다 →
	  // 원래 HTMLInputElement 의 value 설정자로 넣어야 input 이벤트에서 바뀐 값으로 본다 (사용자 2026-11-26)
	  const nativeSet = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
	  const setVal = (e, v) => {
	    e.focus();
	    nativeSet.call(e, v);
	    e.dispatchEvent(new Event('input', {bubbles:true}));
	    e.dispatchEvent(new Event('change', {bubbles:true}));
	  };
	  const captcha = () => all('input[id*=captcha i],input[name*=captcha i],iframe[src*=captcha i],[id*=captcha i] img').some(shown);
	  const submitFor = e => {
	    const f = e.form;
	    return (f && [...f.querySelectorAll('button[type=submit],input[type=submit]')].find(shown))
	      || all('#next_button,#signin_button,#mfa_submit_button,button[type=submit]').find(shown);
	  };
	  const submit = (e, what) => {
	    if (!cfg.autoSubmit) return;
	    if (captcha()) { log(what + ' 뒤 CAPTCHA 가 있어 제출하지 않음 — 직접 입력'); return; }
	    const b = submitFor(e);
	    if (b) setTimeout(() => { b.click(); log(what + ' 제출'); }, 400); else log(what + ' 제출 버튼 못 찾음');
	  };
	  // 틀린 암호로 계속 제출해 계정이 잠기지 않게, 한 페이지에서 칸마다 두 번까지만 채운다
	  const count = {};
	  const fill = async (e, field, what) => {
	    done.add(e);
	    count[field] = (count[field] || 0) + 1;
	    if (count[field] > 2) { if (count[field] === 3) log(what + ' 를 이미 두 번 채움 — 더 채우지 않음'); return false; }
	    const v = await ask({op:'get', field});
	    if (!v) return false;
	    setVal(e, v);
	    // 사이트가 넣은 값을 지우는지 기록 (React 칸 등, 사용자 2026-11-26 AWS MFA 칸)
	    setTimeout(() => { if (e.value !== v) log(what + ' 넣었는데 칸에 남지 않음 (사이트가 지움) — 칸 옆 열쇠 버튼으로 다시 넣기'); }, 400);
	    submit(e, what);
	    return true;
	  };

	  // 채울 칸 오른쪽 안에 열쇠 버튼 (CSS anchor 로 칸에 붙인 popover).
	  // 누르면 다시 채우고, 값이 칸에 남지 않으면 클립보드에 넣고 버튼 오른쪽에 알림 (입력 방해 안 하게 popover, 사용자 2026-11-26)
	  const keys = new Map();   // input → {host, toast}
	  let anchorSeq = 0;
	  const KEY_SVG = '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><circle cx="7.5" cy="15.5" r="4.5"/><path d="M10.7 12.3 20 3"/><path d="m16 7 3 3"/><path d="m18 5 2 2"/></svg>';
	  const label = {username:'아이디', password:'암호', otp:'인증 코드'};
	  const makePop = (anchor, css) => {
	    const host = document.createElement('div');
	    host.setAttribute('popover', 'manual');
	    host.style.cssText = 'position:fixed;margin:0;padding:0;border:0;background:transparent;overflow:visible;inset:auto;position-anchor:' + anchor + ';' + css;
	    const root = host.attachShadow({mode:'closed'});
	    (document.body || document.documentElement).appendChild(host);
	    return {host, root};
	  };
	  const toastFor = (k, text) => {
	    if (!k.toast) {
	      const name = '--ic-key-' + (++anchorSeq);
	      k.host.style.anchorName = name;
	      k.toast = makePop(name, 'left:calc(anchor(right) + 6px);top:anchor(center);translate:0 -50%;pointer-events:none;');
	      k.toast.root.innerHTML = '<style>div{font:12px/1.3 -apple-system,sans-serif;color:#fff;background:rgba(30,30,30,.92);padding:5px 9px;border-radius:7px;white-space:nowrap;box-shadow:0 2px 8px rgba(0,0,0,.25)}</style><div></div>';
	    }
	    k.toast.root.querySelector('div').textContent = text;
	    try { k.toast.host.showPopover(); } catch (x) {}
	    clearTimeout(k.toastTimer);
	    k.toastTimer = setTimeout(() => { try { k.toast.host.hidePopover(); } catch (x) {} }, 2500);
	  };
	  const attach = (e, field) => {
	    if (!e || keys.has(e) || !CSS.supports('anchor-name: --a')) return;
	    const name = '--ic-in-' + (++anchorSeq);
	    e.style.setProperty('anchor-name', name);
	    const k = makePop(name, 'left:calc(anchor(right) - 30px);top:anchor(center);translate:0 -50%;');
	    // 아이콘: 앱이 그려 준 SF Symbol lock.rotation (주소 끝 #가로x세로 는 점 크기), 없으면 열쇠 SVG
	    const m = /#(\d+)x(\d+)$/.exec(cfg.icon || '');
	    const icon = m ? '<img src="' + cfg.icon + '" width="' + m[1] + '" height="' + m[2] + '" alt="">' : KEY_SVG;
	    k.root.innerHTML = '<style>button{all:unset;box-sizing:border-box;width:22px;height:22px;border-radius:50%;display:grid;place-items:center;cursor:pointer;color:#fff;background:#0a84ff;box-shadow:0 1px 3px rgba(0,0,0,.3)}button:hover{background:#0070e0}img{display:block;pointer-events:none}</style><button title="iConsole: ' + label[field] + ' 다시 채우기">' + icon + '</button>';
	    keys.set(e, k);
	    const b = k.root.querySelector('button');
	    b.addEventListener('mousedown', ev => ev.preventDefault());   // 칸의 초점을 뺏지 않게
	    b.addEventListener('click', async ev => {
	      if (!ev.isTrusted) return;    // 페이지 스크립트가 누른 건 무시 (클립보드에 암호가 가지 않게)
	      const v = await ask({op:'get', field});
	      if (!v) { toastFor(k, label[field] + ' 값이 없습니다'); return; }
	      setVal(e, v);
	      await new Promise(r => setTimeout(r, 300));
	      if (e.value === v) { toastFor(k, label[field] + ' 채움'); return; }
	      const copied = await ask({op:'copy', field});
	      log(label[field] + ' 칸에 값이 남지 않아 클립보드에 복사');
	      toastFor(k, copied ? '클립보드에 복사함 — ⌘V 로 붙여 넣기' : '복사하지 못함');
	    });
	    try { k.host.showPopover(); } catch (x) {}
	  };
	  // 칸이 사라지거나 안 보이면 버튼도 치운다
	  const sweep = () => {
	    for (const [e, k] of keys) {
	      const vis = e.isConnected && shown(e);
	      try { vis ? (k.host.matches(':popover-open') || k.host.showPopover()) : k.host.hidePopover(); } catch (x) {}
	      if (!e.isConnected) { k.host.remove(); k.toast?.host.remove(); keys.delete(e); }
	    }
	  };
	  // 사용자 정의 계정: 칸 이름(name · id) 또는 CSS 선택자(#·.·[ 로 시작)
	  const F = cfg.fields || {};
	  const bySpec = spec => {
	    if (!spec) return null;
	    try { return /^[#.\[]/.test(spec) ? document.querySelector(spec) : (document.getElementsByName(spec)[0] || document.getElementById(spec)); } catch (e) { return null; }
	  };
	  let busy = false;
	  let loggedNoCode = false;
	  const tick = async () => {
	    if (busy) return; busy = true;
	    try {
	      if (cfg.kind === 'aws') {
	        // IAM 사용자 로그인 화면(계정 ID·IAM 사용자 이름·암호)이면 채우지 않고 "루트 사용자 이메일로 로그인" 링크로 넘어간다
	        const iam = all('input').find(e => shown(e) && e.type !== 'hidden' && /^account$|account.?id|alias|계정 ?id|별칭/i.test(desc(e)));
	        if (iam) {
	          const link = all('a,button,[role=button],[role=link]').find(e => shown(e) && /root/i.test(e.textContent + ' ' + e.id) && !/iam/i.test(e.textContent));
	          if (link && !done.has(link)) { done.add(link); log('IAM 로그인 화면 → 루트 로그인 링크 누름: ' + link.textContent.trim().slice(0, 60)); link.click(); }
	          else if (!link && !done.has(iam)) { done.add(iam); log('IAM 로그인 화면인데 루트 로그인 링크를 못 찾음'); }
	          return;
	        }
	        const root = all('input[type=radio]').find(r => /root/i.test(r.id + ' ' + r.value + ' ' + r.name));
	        if (root && !root.checked && !done.has(root)) {
	          done.add(root); root.click();
	          if (!root.checked) { const l = root.id && document.querySelector('label[for="' + root.id + '"]'); if (l) l.click(); }
	          log('루트 사용자 고름 (' + (root.checked ? '됨' : '안 됨') + ')');
	        }
	      }
	      sweep();
	      const ok = e => e && shown(e) && !done.has(e) && !e.value;
	      const users = (F.user ? [bySpec(F.user)] : all('input[type=email],input#resolving_input,input[name=email],input[autocomplete~=username],input[name=identifier],input#account_name_text_field,input[name=username],input[name=login],input[id=username],input[id=login]')).filter(e => e && shown(e));
	      const passes = (F.pass ? [bySpec(F.pass)] : all('input[type=password]')).filter(e => e && shown(e) && !/captcha/i.test(e.id + e.name));
	      const isCode = e => e.type !== 'password' && e.type !== 'hidden' && e.type !== 'checkbox' && e.type !== 'radio' && !/captcha/i.test(e.id + e.name);
	      const codes = (F.otp ? [bySpec(F.otp)] : all('input[autocomplete=one-time-code],input[id*=mfa i],input[name*=mfa i],input[id*=otp i],input[name*=otp i],input[name=totpPin],input[id=totpPin],input[name*=twofactor i],input[name*="2fa" i]')).filter(e => e && shown(e) && isCode(e));
	      // 찾은 칸마다 열쇠 버튼 (값이 이미 있어도)
	      users.forEach(e => attach(e, 'username'));
	      passes.forEach(e => attach(e, 'password'));
	      codes.forEach(e => attach(e, 'otp'));
	      // 채우지 못한 칸(두 번 채움 · 값 없음) 때문에 다음 칸으로 못 넘어가는 일이 없게, 실제로 채운 때만 멈춘다
	      const user = users.find(ok);
	      if (user && await fill(user, 'username', '아이디')) return;
	      const pass = passes.find(ok);
	      if (pass && await fill(pass, 'password', '암호')) return;
	      const okCode = e => shown(e) && !done.has(e) && !e.value && isCode(e);
	      let code = codes.find(okCode);
	      const cands = F.otp ? [] : all('input[type=tel],input[type=text],input[type=number],input:not([type])').filter(okCode);
	      // 칸 이름은 아무것이어도 label · placeholder 가 "MFA code" · "enter code" · "인증 코드" 같으면 코드 칸
	      // (새 AWS 로그인 화면 "Additional verification required" 의 MFA 칸이 id · name 에 mfa 가 없어 안 채워졌다, 사용자 2026-11-26)
	      if (!code) code = cands.find(e => codeHint.test(desc(e)));
	      // 2단계 인증 화면(구글 /challenge/totp 등, 또는 제목이 MFA · verification 인 화면)이면 보이는 빈 글·숫자 칸 하나를 코드 칸으로 본다
	      // (구글 "Google OTP 앱에서 인증 코드 받기" 칸이 위 이름에 안 걸려 안 채워졌다, 사용자 2026-11-23)
	      if (!code && cands.length && (/challenge\/totp|totp|mfa|otp|2sv|2fa|two.?step|two.?factor|verif/i.test(location.pathname + location.search)
	          || all('h1,h2,h3,legend,[role=heading]').some(h => h.offsetHeight > 0 && /verification|multi.?factor|mfa|two.?step|2단계|인증/i.test(h.textContent)))) {
	        if (cands.length === 1) code = cands[0];
	        else if (!loggedNoCode) { loggedNoCode = true; log('2단계 화면인데 코드 칸을 못 정함: ' + all('input').filter(shown).map(e => (e.type || '') + '#' + (e.id || '') + '[' + (e.name || '') + ']').join(' ')); }
	      }
	      if (code) { attach(code, 'otp'); await fill(code, 'otp', 'OTP'); return; }
	    } finally { busy = false; }
	  };
	  log('로그인 페이지 감지: ' + location.hostname + location.pathname);
	  new MutationObserver(() => tick()).observe(document.documentElement, {subtree:true, childList:true, attributes:true, attributeFilter:['style','class','hidden']});
	  setInterval(tick, 800);
	  tick();
	})();
	"""#

	// 페이지 시작 때 넣는 스크립트 (page 세계): 패스키 지원 여부, credentials 결과, 콘솔 오류를 기록한다
	static let probe = #"""
	(function(){
	  const post = m => { try { webkit.messageHandlers.ic.postMessage(String(m)) } catch(e){} };
	  for (const k of ['error']) { const o = console[k]; console[k] = function(...a){ post('console.'+k+': '+a.map(String).join(' ').slice(0,300)); return o.apply(console, a) } }
	  window.addEventListener('error', e => post('JS 오류: '+e.message));
	  if (navigator.credentials) {
	    for (const k of ['get','create']) {
	      const f = navigator.credentials[k].bind(navigator.credentials);
	      navigator.credentials[k] = function(o){
	        post('credentials.'+k+' 호출: '+Object.keys(o||{}).join(',')+(o && o.mediation ? ' mediation='+o.mediation : ''));
	        return f(o).then(r => { post('credentials.'+k+' 성공: '+(r && r.type)); return r }, e => { post('credentials.'+k+' 실패: '+e.name+' '+e.message); throw e });
	      };
	    }
	  }
	})();
	"""#
}
