const { test } = require("node:test");
const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const { join } = require("node:path");
const vm = require("node:vm");

// Exercise the page controllers with a fixed clock, without starting a WLAN scan.
function dashboard() {
  const elements = new Map();
  function element() {
    return {
      dataset: {}, children: [], listeners: {}, classList: { toggle() {} },
      lastElementChild: {}, style: {},
      append(...items) { this.children.push(...items); },
      replaceChildren(...items) { this.children = items; },
      setAttribute(key, value) { this[key] = value; },
      addEventListener(key, action) { this.listeners[key] = action; },
    };
  }
  function get(id) {
    if (!elements.has(id)) elements.set(id, element());
    return elements.get(id);
  }
  const context = vm.createContext({
    document: {
      getElementById: get, querySelector: get, querySelectorAll: () => [],
      createElement: element, createElementNS: element, createTextNode: String,
    },
    performance: { now: () => 0 }, matchMedia: () => ({ matches: false }),
    addEventListener() {}, requestAnimationFrame: () => 1,
    fetch: () => new Promise(() => {}), AbortSignal,
  });
  for (const file of ["air-map.js", "app.js"]) {
    vm.runInContext(readFileSync(join(__dirname, "../web", file), "utf8"), context);
  }
  return { get, run: (code) => vm.runInContext(code, context) };
}

function episodePage(snapshots) {
  const page = dashboard();
  page.run('air.readArchive(' + JSON.stringify(snapshots) + ')');
  page.run('air.readState({bands: [], latency: [], episodes: [{id:"lag", at:100000, route:"router"}]})');
  page.run('air.replayNearest(100000)');
  return page;
}

test("replay selects the closest frame on either side and excludes distant frames", () => {
  for (const [times, expected] of [
    [[60000, 101000], 101000], [[99000, 140000], 99000], [[99000, 101000], 99000],
    [[55000], 55000], [[54999, 145001], null],
  ]) {
    const page = episodePage(times.map(at => ({ key: String(at), at, points: [] })));
    page.run("air.tick(2000)");
    assert.equal(page.run("air.frame()?.at ?? null"), expected);
  }
});

test("an episode ends even when its first animation frame is delayed", () => {
  const page = episodePage([]);
  assert.equal(page.run("air.tick(60000)"), false);
  assert.equal(page.run("air.eventTime()"), null);
});

test("A/B can capture the restored archive before the first live scan", () => {
  const page = dashboard();
  page.run('air.readArchive([{key:"saved", at:90000, points:[]}])');
  for (const key of ["a", "b"]) page.get("air-set-" + key).listeners.click();
  assert.equal(page.get("air-swap").hidden, false);
  page.get("air-swap").listeners.click();
  assert.equal(page.run("air.frame().key"), "saved");
});

test("empty network list updates when scanning finishes", () => {
  const page = dashboard();
  page.run('state = { points: [], events: [], scanning: true }; renderLists()');
  const message = () => page.get("points").children[0].children[0].textContent;
  assert.match(message(), /Ожидание/);
  page.run('state.scanning = false; renderLists()');
  assert.match(message(), /Видимых точек нет/);
});

test("status displays independent WLAN and SQLite errors", () => {
  const page = dashboard();
  page.run(`connected = true;
    state = { health: {adapter:"unverified", scan:"failed", storage:"degraded"},
      issue:"Отказано в доступе", storage:"Ошибка записи истории" };
    renderStatus();`);
  assert.match(page.get("startup-check").textContent, /Ошибка сканирования.*Ошибка SQLite/);
  assert.match(page.get("notice").textContent, /Отказано в доступе.*Ошибка записи истории/);
});

test("status detects a server returning the same state for too long", () => {
  const page = dashboard();
  page.run(`connected = true;
    state = { health: {adapter:"ready", scan:"fresh", storage:"ready"} };
    receivedAt = -7000;
    renderStatus();`);
  assert.match(page.get("startup-check").textContent, /перестала присылать/);
  assert.equal(page.get("connection").lastElementChild.textContent, "Обновления остановились");
});

test("blocked radio scan leaves the connection dashboard in diagnostics mode", () => {
  const page = dashboard();
  page.run(`connected = true;
    state = { points: [], events: [], health: {adapter:"ready", scan:"blocked", storage:"ready"} };
    renderStatus();
    renderLists();`);
  assert.equal(page.get("connection").lastElementChild.textContent, "Диагностика связи");
  assert.match(page.get("startup-check").textContent, /Сканирование ограничено Windows/);
  assert.match(page.get("points").children[0].children[0].textContent, /ограничено Windows/);
  assert.equal(page.get("notice").hidden, true);
});

test("imports a VREM scan and displays its own and neighboring access points", () => {
  const page = dashboard();
  const report = [
    "Time Stamp|SSID|BSSID|Strength|Primary Channel|Primary Frequency|Center Channel|Center Frequency|Width (Range)|Distance|",
    "2026/11/18-21:12:55|Дом|12:34:56:78:90:ab|-43dBm|36|5180MHz|42|5210MHz|80MHz (5170 - 5250)|~1m|",
    "2026/11/18-21:12:55|SSID|с разделителем|aa:bb:cc:dd:ee:ff|-71dBm|6|2437MHz|6|2437MHz|20MHz (2427 - 2447)|~2m|",
    "2026/11/18-21:12:55|Сеть 6 ГГц|aa:aa:aa:aa:aa:aa|-60dBm|5|5975MHz|5|5975MHz|20MHz (5965 - 5985)|~2m|",
  ].join("\r\n");
  page.get("phone-report").value = report;
  page.get("phone-home").value = "Дом";
  page.get("phone-import").listeners.submit({ preventDefault() {} });
  assert.match(page.get("phone-import-status").textContent, /точек: 2/);
  assert.match(page.get("history-time").textContent, /Android/);
  assert.equal(page.run("selectedFrame().points[0].segments[0].Left"), 5170);
  assert.equal(page.run("selectedFrame().points[0].own"), true);
  assert.equal(page.run("selectedFrame().points[1].name"), "SSID|с разделителем");
  assert.equal(page.run('spectrumFrames.length'), 1);
  page.run("windowsFrames = []; updateSpectrum()");
  assert.equal(page.run('selectedFrame().source'), "android");
});

test("phone snapshots do not imply a radio cause of a Windows latency episode", () => {
  const page = episodePage([{ key: "phone", at: 100000, points: [], source: "android" }]);
  page.run("air.tick(2000)");
  assert.equal(page.run("air.frame()"), null);
});

test("six GHz is optional observed radio band in Canvas with no invented channel advice", () => {
  const page = dashboard();
  assert.equal(page.run('sources.find(b => b.key === "6").suffix'), "6");
  assert.equal(typeof page.get("spectrum-6").listeners.click, "function");
  assert.equal(typeof page.get("waterfall-6").listeners.click, "function");
});
