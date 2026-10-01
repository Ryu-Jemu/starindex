// Admin page (PLAN 3.5): run history (QueryDSL filter), run a job now, live manifest, API quota.
// The token lives in sessionStorage only (gone when the tab closes); every DOM write uses textContent.
"use strict";
const $ = (id) => document.getElementById(id);
const state = { page: 0, size: 20, total: 0, zone: "", timer: null };
const tokenKey = "starindex.admin.token";

function token() { return sessionStorage.getItem(tokenKey); }

async function api(path, options = {}) {
  const headers = { "Accept": "application/json", ...(options.body ? { "Content-Type": "application/json" } : {}) };
  if (token()) headers["Authorization"] = "Bearer " + token();
  const res = await fetch("/api/admin" + path, { ...options, headers });
  if (res.status === 401 && !path.startsWith("/auth/")) { showLogin("세션이 끝났습니다. 다시 로그인하세요."); throw new Error("401"); }
  const text = await res.text();
  let body = null;
  try { body = text ? JSON.parse(text) : null; } catch { body = { error: text }; }
  return { status: res.status, body };
}

function el(tag, text, cls) {
  const e = document.createElement(tag);
  if (text !== undefined && text !== null) e.textContent = String(text);
  if (cls) e.className = cls;
  return e;
}

function showLogin(message) {
  sessionStorage.removeItem(tokenKey);
  clearInterval(state.timer);
  $("app-view").classList.add("d-none");
  $("logout").classList.add("d-none");
  $("who").textContent = "";
  $("login-view").classList.remove("d-none");
  $("login-error").textContent = message || "";
}

async function showApp() {
  $("login-view").classList.add("d-none");
  $("app-view").classList.remove("d-none");
  $("logout").classList.remove("d-none");
  const { body } = await api("/etl/jobs");
  state.zone = body.serverZone || "";
  $("who").textContent = "서버 시간대 " + state.zone + (body.serviceKey ? "" : " · data.go.kr 키 없음");
  for (const sel of [$("f-job"), $("run-job")]) {
    while (sel.options.length > (sel.id === "f-job" ? 1 : 0)) sel.remove(sel.options.length - 1);
    for (const j of body.jobs) sel.add(new Option(j, j));
  }
  await Promise.all([loadRuns(), loadManifest(), loadQuota()]);
  clearInterval(state.timer);
  state.timer = setInterval(() => { loadRuns(); loadQuota(); }, 15000);
}

const badge = { COMPLETED: "success", FAILED: "danger", STARTED: "info", STARTING: "info", STOPPED: "warning", ABANDONED: "secondary", UNKNOWN: "secondary" };

function fmt(t) { return t ? String(t).replace("T", " ").slice(0, 19) : "-"; }
function duration(a, b) {
  if (!a || !b) return "-";
  const s = (new Date(b) - new Date(a)) / 1000;
  return s >= 60 ? Math.floor(s / 60) + "분 " + Math.round(s % 60) + "초" : s.toFixed(1) + "초";
}

async function loadRuns() {
  const q = new URLSearchParams({ sort: $("f-sort").value, page: state.page, size: state.size });
  if ($("f-job").value) q.set("job", $("f-job").value);
  if ($("f-status").value) q.set("status", $("f-status").value);
  if ($("f-since").value) q.set("since", $("f-since").value);
  const { status, body } = await api("/etl/runs?" + q);
  const tbody = $("runs");
  tbody.replaceChildren();
  if (status !== 200) { tbody.append(rowOf([el("td", body && body.error, "text-danger")])); return; }
  state.total = body.total;
  for (const r of body.runs) {
    const st = el("span", r.status, "badge text-bg-" + (badge[r.status] || "secondary"));
    const tr = rowOf([el("td", r.id), el("td", r.jobName), tdOf(st), el("td", fmt(r.startTime)),
      el("td", duration(r.startTime, r.endTime), "text-end"), el("td", r.exitCode)]);
    tr.addEventListener("click", () => openRun(r.id));
    tbody.append(tr);
  }
  const from = body.total === 0 ? 0 : state.page * state.size + 1;
  $("runs-info").textContent = from + "–" + Math.min((state.page + 1) * state.size, body.total) + " / " + body.total + "건";
  $("prev").disabled = state.page === 0;
  $("next").disabled = (state.page + 1) * state.size >= body.total;
}

function rowOf(cells) { const tr = el("tr"); tr.append(...cells); return tr; }
function tdOf(child) { const td = el("td"); td.append(child); return td; }

async function openRun(id) {
  const { status, body } = await api("/etl/runs/" + id);
  $("run-modal-title").textContent = status === 200 ? "#" + body.id + " " + body.jobName + " · " + body.status : "실행 #" + id;
  const root = $("run-modal-body");
  root.replaceChildren();
  if (status !== 200) { root.append(el("p", "불러오지 못했습니다 (" + status + ")", "text-danger")); }
  else {
    root.append(el("p", "시작 " + fmt(body.startTime) + " · 종료 " + fmt(body.endTime) + " (" + state.zone + ")", "small text-secondary"));
    const params = Object.entries(body.params).map(([k, v]) => k + "=" + v).join("  ");
    root.append(el("p", "파라미터: " + (params || "-"), "small"));
    for (const s of body.steps) {
      const card = el("div", null, "border rounded p-2 mb-2");
      card.append(el("div", s.name + " · " + s.status + " · " + s.exitCode, "fw-semibold"));
      if (s.summary) card.append(el("div", s.summary, "summary"));
      if (s.exitDescription) card.append(el("div", s.exitDescription, "summary text-danger"));
      root.append(card);
    }
    for (const f of body.failures) root.append(el("div", f, "summary text-danger"));
  }
  bootstrap.Modal.getOrCreateInstance($("run-modal")).show();
}

async function loadManifest() {
  const dl = $("manifest");
  dl.replaceChildren();
  const res = await fetch("/api/admin/packs/manifest", { headers: { "Authorization": "Bearer " + token() } });
  if (res.status !== 200) { dl.append(el("dd", res.status === 404 ? "아직 발행된 팩이 없습니다" : "오류 " + res.status, "col-12")); return; }
  const m = await res.json();
  const idx = (m.packs || {}).index || {};
  for (const [k, v] of [["버전", idx.version], ["밤", idx.nightDate], ["발표", idx.issuedAt], ["갱신", m.generatedAt], ["크기", idx.bytes + " B"]]) {
    dl.append(el("dt", k, "col-4"), el("dd", v ?? "-", "col-8 text-break"));
  }
}

async function loadQuota() {
  const { status, body } = await api("/quota");
  const dl = $("quota");
  dl.replaceChildren();
  if (status !== 200) return;
  $("quota-day").textContent = body.day + " · 일 " + body.dailyQuota + "회";
  for (const [k, v] of Object.entries(body.used)) dl.append(el("dt", k, "col-7 fw-normal"), el("dd", v, "col-5 text-end"));
}

$("login-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const { status, body } = await api("/auth/login", { method: "POST", body: JSON.stringify({ username: $("username").value, password: $("password").value }) });
  $("password").value = "";
  if (status === 200) { sessionStorage.setItem(tokenKey, body.token); showApp(); }
  else $("login-error").textContent = (body && body.error) || "로그인 실패 (" + status + ")";
});

$("logout").addEventListener("click", async () => {
  try { await api("/auth/logout", { method: "POST" }); } finally { showLogin(); }
});

$("run-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const params = {};
  for (const k of ["base", "nightDate", "from", "month"]) { const v = $("p-" + k).value.trim(); if (v) params[k] = v; }
  const job = $("run-job").value;
  const { status, body } = await api("/etl/jobs/" + encodeURIComponent(job) + "/run", { method: "POST", body: JSON.stringify({ params }) });
  const out = $("run-result");
  out.className = "small " + (status === 202 ? "text-success" : "text-danger");
  out.textContent = status === 202 ? job + " 시작 · 실행 #" + body.executionId : (body && body.error) || "실패 " + status;
  state.page = 0;
  setTimeout(loadRuns, 800);
});

for (const id of ["f-job", "f-status", "f-since", "f-sort"]) $(id).addEventListener("change", () => { state.page = 0; loadRuns(); });
$("refresh").addEventListener("click", () => { loadRuns(); loadManifest(); loadQuota(); });
$("prev").addEventListener("click", () => { if (state.page > 0) { state.page--; loadRuns(); } });
$("next").addEventListener("click", () => { state.page++; loadRuns(); });

if (token()) showApp().catch(() => {}); else showLogin();
