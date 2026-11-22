// Baby-Log 위젯 (Scriptable) — 잠금화면 / 홈화면
// 처음 한 번 Scriptable 앱에서 ▶︎ 실행하면 가족 코드를 물어봐요 (이 폰 키체인에 저장).
const API = "https://ydkjimnnyacfdllksblq.supabase.co";
const KEY = "sb_publishable_KKuETYmezjuuXTAfeONKdg_I-quu3cq";
// 위젯을 누르면 열 주소. 기본은 Safari.
// 단축어 '아기기록열기'(동작: URL 열기 webapp://jaybaek-git.github.io/Baby-Log/)를 만들었다면 아래 OPEN_SHORTCUT 을 true 로.
const OPEN_SHORTCUT = false;
const APP = OPEN_SHORTCUT ? "shortcuts://run-shortcut?name=" + encodeURIComponent("아기기록열기") : "https://jaybaek-git.github.io/Baby-Log/";
const KC = "babylog_code";

async function getCode() {
  if (Keychain.contains(KC)) return Keychain.get(KC);
  if (config.runsInWidget) return null;
  const a = new Alert();
  a.title = "가족 코드";
  a.message = "Baby-Log 가족 코드를 붙여넣어 주세요";
  a.addTextField("가족 코드");
  a.addAction("저장");
  a.addCancelAction("취소");
  if (await a.present() < 0) return null;
  const c = a.textFieldValue(0).trim();
  if (c) Keychain.set(KC, c);
  return c || null;
}

async function load(code) {
  const r = new Request(API + "/rest/v1/rpc/widget_status");
  r.method = "POST";
  r.headers = { apikey: KEY, "Content-Type": "application/json" };
  r.body = JSON.stringify({ p_code: code });
  return await r.loadJSON();
}

const hm = d => { const f = new DateFormatter(); f.dateFormat = "HH:mm"; return f.string(d); };
const ago = d => { const m = Math.max(0, Math.round((Date.now() - d) / 60000)); return m < 60 ? `${m}분` : `${Math.floor(m / 60)}:${String(m % 60).padStart(2, "0")}`; };
const dia = n => (n === "대변" ? "💩" : n === "둘다" ? "💩💧" : n === "소변" ? "💧" : "🩲");

function line(w, text, size, bold, color) {
  const t = w.addText(text);
  t.font = bold ? Font.boldSystemFont(size) : Font.systemFont(size);
  if (color) t.textColor = color;
  t.lineLimit = 1;
  t.minimumScaleFactor = 0.6;
  return t;
}
function timerLine(w, prefix, date, size, bold) {
  const s = w.addStack();
  s.centerAlignContent();
  const a = s.addText(prefix);
  a.font = bold ? Font.boldSystemFont(size) : Font.systemFont(size);
  const d = s.addDate(date);
  d.applyTimerStyle();
  d.font = bold ? Font.boldSystemFont(size) : Font.systemFont(size);
  d.lineLimit = 1;
  return s;
}

async function build() {
  const fam = config.widgetFamily || "medium";
  const w = new ListWidget();
  w.url = APP;
  w.refreshAfterDate = new Date(Date.now() + 5 * 60000);
  const code = await getCode();
  if (!code) { line(w, "Scriptable에서 한 번 실행해 가족 코드를 넣어 주세요", 11); return w; }
  let s;
  try { s = await load(code); } catch (e) { line(w, "불러오기 실패", 12); return w; }
  if (s && s.message) { line(w, "가족 코드 확인 필요", 12); Keychain.remove(KC); return w; }

  const lf = s.last_feed, due = s.due_at ? new Date(s.due_at) : null, ld = s.last_diaper;
  const lfT = lf ? new Date(lf.at) : null, ldT = ld ? new Date(ld.at) : null;
  const sleep = s.sleep_since ? new Date(s.sleep_since) : null;
  const over = due && due < new Date();
  const feedTxt = lf ? `🍼 ${hm(lfT)}${lf.value ? " · " + lf.value + "ml" : ""}` : "🍼 기록 없음";

  if (fam === "accessoryInline") {
    line(w, lf ? `🍼 ${hm(lfT)} · 다음 ${due ? hm(due) : "-"}` : "🍼 기록 없음", 12);
    return w;
  }
  if (fam === "accessoryCircular") {
    // 진행 링 (새로 고칠 때 기준) + 가운데 남은 시간 (실시간)
    const start = s.last_end ? new Date(s.last_end) : lfT;
    const p = due && start ? Math.max(0, Math.min(1, (Date.now() - start) / (due - start))) : 0;
    const c = new DrawContext(); c.size = new Size(120, 120); c.opaque = false; c.respectScreenScale = true;
    const arc = (from, to, col, wdt) => {
      const path = new Path(), pts = [];
      for (let k = 0; k <= 60; k++) { const a = (-90 + (from + (to - from) * k / 60) * 360) * Math.PI / 180; pts.push(new Point(60 + 52 * Math.cos(a), 60 + 52 * Math.sin(a))); }
      path.addLines(pts); c.addPath(path); c.setStrokeColor(col); c.setLineWidth(wdt); c.strokePath();
    };
    arc(0, 1, new Color("#FFFFFF", 0.25), 9);
    if (p > 0) arc(0, p, new Color("#FFFFFF", 1), 9);
    w.backgroundImage = c.getImage();
    const t1 = w.addText(over ? "지남" : "🍼 남음"); t1.font = Font.systemFont(9); t1.centerAlignText(); t1.textOpacity = 0.85;
    if (due) { const d = w.addDate(due); d.applyTimerStyle(); d.font = Font.boldRoundedSystemFont(15); d.centerAlignText(); d.lineLimit = 1; d.minimumScaleFactor = 0.5; }
    else { const t = w.addText("-"); t.font = Font.boldSystemFont(15); t.centerAlignText(); }
    const t3 = w.addText(due ? hm(due) : ""); t3.font = Font.systemFont(9); t3.centerAlignText(); t3.textOpacity = 0.85;
    return w;
  }
  const P = String(args.widgetParameter || "").trim();
  if (fam === "accessoryRectangular" && P) {
    // 한 가지만 크게: 위젯 설정의 Parameter 에 "마지막" 또는 "다음"
    const one = (label, big, sub, timerDate) => {
      const l = w.addText(label); l.font = Font.systemFont(12); l.textOpacity = 0.85; l.lineLimit = 1;
      const b = w.addText(big); b.font = Font.boldRoundedSystemFont(36); b.lineLimit = 1; b.minimumScaleFactor = 0.6;
      if (timerDate) { const r = w.addStack(); r.centerAlignContent(); const a = r.addText(sub); a.font = Font.systemFont(12); a.textOpacity = 0.85;
        const d = r.addDate(timerDate); d.applyTimerStyle(); d.font = Font.boldSystemFont(12); d.lineLimit = 1; d.minimumScaleFactor = 0.7; }
      else { const t = w.addText(sub); t.font = Font.systemFont(12); t.textOpacity = 0.85; t.lineLimit = 1; t.minimumScaleFactor = 0.7; }
    };
    if (/^(마지막|last)/i.test(P)) one("🍼 마지막 수유", lfT ? hm(lfT) : "-", lfT ? `${ago(lfT)} 전${lf.value ? " · " + lf.value + "ml" : ""}` : "기록 없음");
    else one(over ? "⚠️ 다음 수유 (지남)" : "🍼 다음 수유", due ? hm(due) : "-", over ? "지난 " : "남은 ", due);
    return w;
  }
  if (fam === "accessoryRectangular") {
    const row = w.addStack();
    row.layoutHorizontally();
    row.centerAlignContent();
    const col = (parent) => { const c = parent.addStack(); c.layoutVertically(); return c; };
    const small = (c, txt) => { const t = c.addText(txt); t.font = Font.systemFont(11); t.textOpacity = 0.8; t.lineLimit = 1; t.minimumScaleFactor = 0.6; return t; };
    const bigTxt = (c, txt) => { const t = c.addText(txt); t.font = Font.boldRoundedSystemFont(26); t.lineLimit = 1; t.minimumScaleFactor = 0.5; return t; };
    // 왼쪽: 마지막 수유
    const L = col(row);
    small(L, "🍼 마지막");
    bigTxt(L, lfT ? hm(lfT) : "-");
    small(L, lfT ? `${ago(lfT)} 전${lf.value ? " · " + lf.value + "ml" : ""}` : "기록 없음");
    row.addSpacer();
    const bar = row.addStack(); bar.size = new Size(1, 48); bar.backgroundColor = new Color("#FFFFFF", 0.35);
    row.addSpacer();
    // 오른쪽: 다음 수유까지
    const R = col(row);
    small(R, over ? "⚠️ 다음 (지남)" : "🍼 다음");
    bigTxt(R, due ? hm(due) : "-");
    if (due) { const d = R.addDate(due); d.applyTimerStyle(); d.font = Font.boldSystemFont(11); d.lineLimit = 1; d.minimumScaleFactor = 0.6; d.textOpacity = 0.9; }
    else small(R, "");
    row.addSpacer();
    return w;
  }
  // 홈 화면 (small / medium / large)
  w.backgroundColor = Color.dynamic(new Color("#FFFFFF"), new Color("#1C1C1E"));
  const sub = Color.dynamic(new Color("#666666"), new Color("#AAAAAA"));
  line(w, `${s.name} 기록`, 12, true, sub);
  w.addSpacer(4);
  line(w, feedTxt, fam === "small" ? 15 : 17, true);
  if (lfT) line(w, `${ago(lfT)} 전`, 12, false, sub);
  w.addSpacer(4);
  if (due) timerLine(w, over ? "⚠️ 지남 " : "다음 ", due, fam === "small" ? 13 : 15, true);
  w.addSpacer(4);
  if (sleep) timerLine(w, "😴 자는 중 ", sleep, 12, false);
  line(w, `${ld ? dia(ld.note) + " " + hm(ldT) : "🩲 -"}`, 12, false, sub);
  line(w, `오늘 ${s.today.feeds}회 · ${s.today.ml}ml · 🩲${s.today.diapers}`, 11, false, sub);
  return w;
}

const widget = await build();
if (config.runsInWidget) Script.setWidget(widget);
else await widget.presentMedium();
Script.complete();
