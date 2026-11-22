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
	  const done = new WeakSet();
	  const setVal = (e, v) => {
	    e.focus();
	    e.value = v;
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
	    submit(e, what);
	    return true;
	  };
	  let busy = false;
	  const tick = async () => {
	    if (busy) return; busy = true;
	    try {
	      if (cfg.kind === 'aws') {
	        // IAM 사용자 로그인 화면(계정 ID·IAM 사용자 이름·암호)이면 채우지 않고 "루트 사용자 이메일로 로그인" 링크로 넘어간다
	        const desc = e => [e.id, e.name, e.placeholder, e.getAttribute('aria-label'), ...[...(e.labels || [])].map(l => l.textContent)].join(' ');
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
	      const user = all('input[type=email],input#resolving_input,input[name=email],input[autocomplete~=username],input[name=identifier],input#account_name_text_field')
	        .find(e => shown(e) && !done.has(e) && !e.value);
	      if (user) { await fill(user, 'username', '아이디'); return; }
	      const pass = all('input[type=password]').find(e => shown(e) && !done.has(e) && !e.value && !/captcha/i.test(e.id + e.name));
	      if (pass) { await fill(pass, 'password', '암호'); return; }
	      const code = all('input[autocomplete=one-time-code],input[id*=mfa i],input[name*=mfa i],input[id*=otp i],input[name*=otp i],input[name=totpPin]')
	        .find(e => shown(e) && !done.has(e) && !e.value && e.type !== 'password' && e.type !== 'hidden' && !/captcha/i.test(e.id + e.name));
	      if (code) { await fill(code, 'otp', 'OTP'); return; }
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
