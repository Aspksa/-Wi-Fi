"use strict";

const byId = (id) => document.getElementById(id);
const homeField = byId("home");
const stopped = byId("stop-tracking");
const sources = [
  { key: "2.4", suffix: "24", label: "2,4 ГГц", min: 2399, max: 2497, channels: [1, 3, 5, 7, 9, 11, 13] },
  { key: "5", suffix: "5", label: "5 ГГц", min: 5145, max: 5910, channels: [36, 48, 64, 100, 116, 132, 149, 161] },
];
const palette = { grid: "#31372f", text: "#9ba495", gold: "#f0bd62", blue: "#8db9c5", glow: "#ec8848", loss: "#f07c70", trail: "#c2a1ed" };
const reduceMotion = matchMedia("(prefers-reduced-motion: reduce)");
let state = null;
let connected = false;
let actionError = "";
let stamp = "";
let frame = 0;
let trail = null;
let databaseMessages = "";
let renderedPoints = "";
let renderedEvents = "";
let renderedHeat = "";
let lastStateTime = 0;
let receivedAt = 0;

function child(tag, text, className) {
  const element = document.createElement(tag);
  if (typeof text === "string") element.textContent = text;
  if (className) element.className = className;
  return element;
}

function renderStatus() {
  const status = byId("connection");
  status.classList.toggle("live", connected && !state?.issue);
  status.classList.toggle("fault", !connected || Boolean(state?.issue));
  status.lastElementChild.textContent = !connected ? "Нет связи" :
    state?.issue ? "Проверить Wi-Fi" : state?.scanning ? "Сканирование" : "Локальный режим";
  byId("refresh").disabled = Boolean(connected && state?.scanning);
  byId("scan-meta").textContent = state?.scanAt ?
    new Date(state.scanAt).toLocaleTimeString("ru-RU") + " · " + state.source + " · " + state.points.length + " точек" :
    "Ожидание первого замера";
  const message = actionError || (!connected ? "Подключение к Wi Fi потеряно. Проверь окно запуска." : state?.issue || databaseMessages);
  const notice = byId("notice");
  notice.textContent = message;
  notice.hidden = !message;
}

function formatDestination(prefix, result) {
  const value = byId(prefix + "-value");
  const loss = byId(prefix + "-loss");
  value.textContent = result?.Tested && result?.Average != null ? result.Average + " мс" : "—";
  loss.textContent = result?.Tested ? result.Lost === 3 ? "Нет ответов" : "Потери " + result.Lost + " из 3" : "Нет замера";
}

function renderHeat() {
  const next = JSON.stringify(state.bands.map((band) => band.heat));
  if (next === renderedHeat) return;
  renderedHeat = next;
  const rows = state.bands.map((band, index) => {
    const row = child("div", null, "heat-row");
    row.append(child("span", sources[index].label, "heat-label"));
    for (const hour of band.heat) {
      const level = hour.score === null ? "" : " level-" + Math.min(4, Math.floor(hour.score / 22));
      const cell = child("span", null, "heat-cell" + level);
      cell.title = hour.hour + " · " + (hour.score === null ? "нет замера" : hour.score + " баллов");
      cell.setAttribute("aria-label", cell.title);
      row.append(cell);
    }
    return row;
  });
  const labels = child("div", null, "heat-row hours");
  labels.append(child("span"));
  state.bands[0].heat.forEach((hour, index) => labels.append(child("span", index % 4 === 0 ? hour.hour.slice(0, 2) : "")));
  byId("heat-grid").replaceChildren(...rows, labels);
}

function renderLists() {
  const pointSignature = JSON.stringify(state.points);
  if (pointSignature !== renderedPoints) {
    renderedPoints = pointSignature;
    const rows = [...state.points].sort((a, b) => Number(b.own) - Number(a.own) || Number(a.stale) - Number(b.stale) || b.signal - a.signal).map((point) => {
      const row = child("tr", null, point.stale ? "stale" : point.own ? "owned" : "");
      const name = child("td", point.name);
      name.title = point.id;
      const action = child("td");
      if (point.tracked) {
        action.append(child("span", "Под наблюдением"));
      } else if (!point.own && !point.stale) {
        const button = child("button", "Следить", "track");
        button.type = "button";
        button.addEventListener("click", () => command("track", point.id));
        action.append(button);
      }
      row.append(name, child("td", point.band.replace(".", ",")), child("td", String(point.channel)), child("td", point.signalText), action);
      return row;
    });
    if (!rows.length) {
      const row = child("tr");
      const empty = child("td", state.scanning ? "Ожидание сканирования." : "Видимых точек нет.", "empty");
      empty.colSpan = 5;
      row.append(empty);
      rows.push(row);
    }
    byId("points").replaceChildren(...rows);
    byId("point-count").textContent = String(state.points.length);
  }
  byId("tracking-name").textContent = state.trackedName ? "Под наблюдением · " + state.trackedName : "";
  byId("tracking-name").hidden = !state.tracked;
  stopped.hidden = !state.tracked;
  const eventSignature = JSON.stringify(state.events);
  if (eventSignature !== renderedEvents) {
    renderedEvents = eventSignature;
    const events = state.events.map((entry) => {
      const row = child("li");
      const time = child("time", entry.At.slice(11, 16));
      time.dateTime = entry.At.replace(" ", "T");
      time.title = entry.At;
      row.append(time, child("span", entry.Message));
      return row;
    });
    byId("events").replaceChildren(...(events.length ? events : [child("li", "Событий пока нет.", "empty")]));
  }
}

function renderState(next) {
  const previous = state?.points?.find((point) => point.id === next.tracked && !point.stale);
  const current = next.points.find((point) => point.id === next.tracked && !point.stale);
  if (previous && current && previous.channel !== current.channel && !reduceMotion.matches) {
    trail = { previous, current, at: performance.now() };
  }
  state = next;
  lastStateTime = next.now;
  receivedAt = performance.now();
  connected = true;
  databaseMessages = state.storage || "";
  if (state.home !== stamp) {
    if (document.activeElement !== homeField) homeField.value = state.home;
    stamp = state.home;
  }
  renderStatus();
  state.bands.forEach((band, index) => {
    const suffix = sources[index].suffix;
    byId("advice-" + suffix).textContent = band.advice;
    byId("band-" + suffix).textContent = band.channel ?
      "Канал " + band.channel + (band.width ? " / " + band.width + " МГц" : "") : "Своя сеть не видна";
  });
  formatDestination("router", state.diagnostics?.Router);
  formatDestination("internet", state.diagnostics?.Internet);
  byId("link").textContent = ({
    ok: "В последнем замере оба адреса ответили.",
    external: "Сбой виден до внешнего адреса. Роутер отвечает стабильно.",
    local: "Есть задержка или потери до роутера.",
    "router-no-reply": "Роутер не ответил на контрольные запросы.",
    "router-ok": "Роутер отвечает. Внешний замер недоступен.",
  })[state.link] || "Ожидание диагностики.";
  renderHeat();
  renderLists();
  scheduleDraw();
}

function viewport(canvas) {
  const width = canvas.clientWidth;
  const height = canvas.clientHeight;
  const scale = Math.min(devicePixelRatio || 1, 2);
  const pixelWidth = Math.floor(width * scale);
  const pixelHeight = Math.floor(height * scale);
  if (canvas.width !== pixelWidth || canvas.height !== pixelHeight) {
    canvas.width = pixelWidth;
    canvas.height = pixelHeight;
  }
  const context = canvas.getContext("2d");
  context.setTransform(scale, 0, 0, scale, 0, 0);
  context.clearRect(0, 0, width, height);
  return { context, width, height };
}

function position(frequency, band, width) {
  return 14 + (frequency - band.min) * (width - 28) / (band.max - band.min);
}

function makeArc(left, right, floor, rise) {
  const path = new Path2D();
  const width = right - left;
  const center = (left + right) / 2;
  path.moveTo(left, floor);
  path.bezierCurveTo(left + width * .24, floor, center - width * .25, floor - rise, center, floor - rise);
  path.bezierCurveTo(center + width * .25, floor - rise, right - width * .24, floor, right, floor);
  path.closePath();
  return path;
}

function drawBand(band, now) {
  const { context, width, height } = viewport(byId("spectrum-" + band.suffix));
  const floor = height - 23;
  const space = floor - 10;
  const points = (state?.points || []).filter((point) => point.band === band.key);
  const local = points.find((point) => point.id === state?.bands.find((item) => item.key === band.key)?.ownId && !point.stale);
  const geometry = (point, segment, delta = 0) => makeArc(
    position(segment.Left + delta, band, width),
    position(segment.Right + delta, band, width),
    floor, Math.max(5, point.signal / 100 * space)
  );
  const localPaths = local ? local.segments.map((segment) => geometry(local, segment)) : [];
  context.font = '10px "Consolas", monospace';
  context.lineWidth = 1;
  context.strokeStyle = palette.grid;
  for (let row = 0; row < 4; row++) {
    const y = floor - row * space / 3;
    context.beginPath();
    context.moveTo(14, y);
    context.lineTo(width - 14, y);
    context.stroke();
  }
  context.fillStyle = palette.text;
  context.textAlign = "center";
  let previousLabel = -Infinity;
  for (const channel of band.channels) {
    const x = position((band.key === "5" ? 5000 : 2407) + channel * 5, band, width);
    if (x - previousLabel < 20) continue;
    context.fillText(String(channel), x, height - 7);
    previousLabel = x;
  }

  if (points.length === 0) {
    context.font = '12px "Segoe UI", sans-serif';
    context.fillText(state?.scanning ? "Сканирование эфира" : "Видимых точек пока нет", width / 2, floor / 2);
  }

  for (const point of [...points].sort((a, b) => Number(a.own) - Number(b.own) || a.signal - b.signal)) {
    const moving = trail?.current.id === point.id && now - trail.at < 2200;
    const progress = moving ? Math.min(1, (now - trail.at) / 690) : 1;
    const shift = moving ? (trail.previous.frequency - point.frequency) * (1 - progress) ** 3 : 0;
    const color = point.own ? palette.gold : moving || point.tracked ? palette.trail : palette.blue;
    point.segments.forEach((segment, index) => {
      const path = geometry(point, segment, index === 0 ? shift : 0);
      const fill = context.createLinearGradient(0, 5, 0, floor);
      fill.addColorStop(0, color + (point.own ? "43" : "27"));
      fill.addColorStop(1, color + "04");
      context.globalAlpha = point.stale ? .35 : 1;
      context.fillStyle = fill;
      context.fill(path);
      if (!point.own && !point.stale && progress === 1) {
        for (const ownPath of localPaths) {
          context.save();
          context.clip(ownPath);
          context.fillStyle = palette.glow + "55";
          context.fill(path);
          context.restore();
        }
      }
      context.lineWidth = point.own || point.tracked ? 1.8 : 1;
      context.strokeStyle = color;
      context.stroke(path);
    });
    const primary = position(point.frequency + shift, band, width);
    context.fillStyle = color;
    context.fillRect(primary - .75, floor - 4, 1.5, 7);
    context.globalAlpha = 1;
  }
  if (trail?.current.band === band.key && now - trail.at < 2200) {
    context.save();
    context.globalAlpha = .8 * (1 - (now - trail.at) / 2200);
    context.strokeStyle = palette.trail;
    context.fillStyle = palette.trail;
    context.setLineDash([3, 4]);
    for (const segment of trail.previous.segments) context.stroke(geometry(trail.previous, segment));
    context.textAlign = "left";
    context.fillText(trail.previous.channel + " → " + trail.current.channel, 16, 15);
    context.restore();
  }
}

function drawLatency(now) {
  const { context, width, height } = viewport(byId("latency"));
  const base = height - 16;
  const usable = width - 52;
  const right = width - 26;
  const currentTime = lastStateTime + (now - receivedAt);
  context.strokeStyle = palette.grid;
  context.lineWidth = 1;
  const grid = [0, 1, 2];
  for (const step of grid) {
    const y = base - step * (base - 8) / 2;
    context.beginPath();
    context.moveTo(15, y);
    context.lineTo(right, y);
    context.stroke();
  }
  context.font = '10px "Consolas", monospace';
  context.fillStyle = palette.text;
  context.textAlign = "left";
  context.fillText("−60 с", 15, height - 2);
  context.textAlign = "right";
  context.fillText("сейчас", right, height - 2);
  let previous = null;
  let hasPulse = false;
  for (const sample of state?.latency || []) {
    const age = Math.max(0, currentTime - sample.at);
    if (age > 60000) continue;
    const x = right - usable * age / 60000;
    const y = sample.lost ? 9 : base - Math.min(1, sample.ms / 120) * (base - 8);
    if (previous && !sample.lost && sample.at - previous.at < 2500) {
      context.strokeStyle = palette.gold;
      context.lineWidth = 1.4;
      context.beginPath();
      context.moveTo(previous.x, previous.y);
      context.lineTo(x, y);
      context.stroke();
    }
    if (sample.lost || sample.ms > 35) {
      const color = sample.lost ? palette.loss : palette.glow;
      context.fillStyle = color;
      context.strokeStyle = color;
      context.beginPath();
      if (sample.lost) {
        context.moveTo(x - 3, y - 3);
        context.lineTo(x + 3, y + 3);
        context.moveTo(x + 3, y - 3);
        context.lineTo(x - 3, y + 3);
        context.stroke();
      } else {
        context.arc(x, y, 2.8, 0, 2 * Math.PI);
        context.fill();
      }
      if (age < 1250 && !reduceMotion.matches) {
        hasPulse = true;
        context.save();
        context.globalAlpha = .72 * (1 - age / 1250);
        context.beginPath();
        context.arc(x, y, 4 + age / 75, 0, 2 * Math.PI);
        context.stroke();
        context.restore();
      }
    }
    previous = sample.lost ? null : { x, y, at: sample.at };
  }
  return hasPulse;
}

function scheduleDraw() {
  if (frame) return;
  frame = requestAnimationFrame((now) => {
    frame = 0;
    for (const band of sources) drawBand(band, now);
    const pulse = drawLatency(now);
    if (trail && now - trail.at >= 2200) trail = null;
    if (trail || pulse) scheduleDraw();
  });
}

for (const band of sources) {
  const canvas = byId("spectrum-" + band.suffix);
  const tooltip = byId("tip-" + band.suffix);
  canvas.addEventListener("pointermove", (event) => {
    const x = event.offsetX;
    const width = canvas.clientWidth;
    const close = (state?.points || []).filter((point) => point.band === band.key)
      .map((point) => ({ point, distance: Math.abs(x - position(point.frequency, band, width)) }))
      .filter((item) => item.distance <= 12)
      .sort((a, b) => a.distance - b.distance || Number(a.point.stale) - Number(b.point.stale) || b.point.signal - a.point.signal)[0];
    tooltip.hidden = !close;
    if (!close) return;
    const point = close.point;
    tooltip.textContent = point.name + " · канал " + point.channel + " · " + point.signalText +
      " · " + (point.measured ? "" : "≈") + point.width + " МГц" + (point.stale ? " · старый замер" : "");
  });
  canvas.addEventListener("pointerleave", () => { tooltip.hidden = true; });
}
addEventListener("resize", scheduleDraw);
scheduleDraw();

async function refresh() {
  try {
    const response = await fetch("/api/state", { cache: "no-store", signal: AbortSignal.timeout(2600) });
    if (!response.ok) throw new Error("state");
    const next = await response.json();
    if (!Array.isArray(next.bands) || next.bands.length !== 2) throw new Error("incomplete");
    renderState(next);
  } catch {
    connected = false;
    renderStatus();
  }
}

async function command(name, value = "") {
  try {
    const response = await fetch("/api/" + name + (value ? "?" + encodeURIComponent(value) : ""), {
      method: "POST", headers: { "X-WiFi-Dashboard": "1" }, signal: AbortSignal.timeout(3000),
    });
    if (!response.ok) throw new Error("command");
    actionError = "";
    renderStatus();
  } catch {
    actionError = "Команда не выполнена. Проверь подключение и попробуй снова.";
    renderStatus();
  }
}

byId("refresh").addEventListener("click", () => command("refresh"));
byId("home-form").addEventListener("submit", (event) => {
  event.preventDefault();
  command("home", homeField.value);
});
stopped.addEventListener("click", () => command("track"));
async function poll() {
  await refresh();
  setTimeout(poll, 950);
}
poll();
