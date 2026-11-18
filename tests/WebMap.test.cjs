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
