"use strict";

const byId = (id) => document.getElementById(id);
const homeField = byId("home");
const stopped = byId("stop-tracking");
const sources = [
  { key: "2.4", suffix: "24", label: "2,4 ГГц", min: 2399, max: 2497, channels: [1, 3, 5, 7, 9, 11, 13] },
  { key: "5", suffix: "5", label: "5 ГГц", min: 5145, max: 5910, channels: [36, 48, 64, 100, 116, 132, 149, 161] },
  { key: "6", suffix: "6", label: "6 ГГц", min: 5925, max: 7130, channels: [1, 33, 65, 97, 129, 161, 193, 225] },
];
const palette = { grid: "#31372f", text: "#9ba495", gold: "#f0bd62", blue: "#8db9c5", glow: "#ec8848", loss: "#f07c70", trail: "#c2a1ed" };
const reduceMotion = matchMedia("(prefers-reduced-motion: reduce)");
let state = null;
let connected = false;
let actionError = "";
let stamp = "";
let frame = 0;
let trail = null;
let renderedPoints = "";
let renderedEvents = "";
let renderedHeat = "";
let lastStateTime = 0;
let receivedAt = 0;
let spectrumFrames = [];
let windowsFrames = [];
let phoneFrames = [];
let frameKey = null;
let pinnedPoint = null;
let latestSpectrumScan = null;
let loadingSpectrum = false;
let revealAt = -Infinity;
const frameBins = new Map();
let overlapHatch;

function overlapPattern(context) {
  if (!overlapHatch) {
    const tile = document.createElement("canvas");
    tile.width = tile.height = 8;
    const ink = tile.getContext("2d");
    ink.strokeStyle = "#eaaa617a";
    ink.beginPath();
    ink.moveTo(0, 8);
    ink.lineTo(8, 0);
    ink.stroke();
    overlapHatch = context.createPattern(tile, "repeat");
  }
  return overlapHatch;
}
const historyPosition = byId("history-position");

const air = AirMap.create({
  bands: sources,
  sizeCanvas: viewport,
  resetView() { frameKey = null; },
  chooseSlice(key) { if (selectedFrame()?.key !== key) chooseFrame(key); },
  changed() {
    renderMapControls();
    scheduleDraw();
  },
});

function child(tag, text, className) {
  const element = document.createElement(tag);
  if (typeof text === "string") element.textContent = text;
  if (className) element.className = className;
  return element;
}

function renderStatus() {
  const status = byId("connection");
  const health = state?.health;
  const scanBlocked = health?.scan === "blocked";
  const stalled = connected && performance.now() - receivedAt > 6500;
  const fault = !connected || stalled || Boolean(state?.issue || state?.storage) ||
    health?.scan === "stale" || health?.scan === "slow";
  status.classList.toggle("live", !fault && health?.scan === "fresh");
  status.classList.toggle("fault", fault);
  status.lastElementChild.textContent = !connected ? "Нет связи" :
    stalled ? "Обновления остановились" : fault ? "Нужна проверка" :
    scanBlocked ? "Диагностика связи" : state?.scanning ? "Сканирование" : "Локальный режим";
  byId("refresh").disabled = Boolean(connected && state?.scanning);
  byId("scan-meta").textContent = state?.scanAt ?
    new Date(state.scanAt).toLocaleTimeString("ru-RU") + " · " + state.source + " · " + state.points.length + " точек" :
    scanBlocked ? "Показываем задержку и потери" : "Ожидание первого замера";
  const adapter = { pending: "Проверка адаптера", ready: "Адаптер доступен", unverified: "Адаптер не подтверждён" };
  const scan = {
    pending: "Ждём первый замер", failed: "Ошибка сканирования", empty: "Точек доступа не видно",
    blocked: "Сканирование ограничено Windows", slow: "Windows долго не завершает сканирование",
    unverified: "Возраст замеров неизвестен", fresh: "Свежие замеры", stale: "Замеры устарели",
  };
  const storage = { ready: "SQLite доступна", degraded: "Ошибка SQLite", unavailable: "SQLite недоступна" };
  const result = connected && !stalled && health ?
    [adapter[health.adapter], scan[health.scan], storage[health.storage]].filter(Boolean).join(" · ") :
    stalled ? "Служба замеров перестала присылать обновления." : "Ожидание ответа службы замеров";
  const router = state?.router;
  const routerLine = router?.address ? " · Роутер " + router.address + (router.model ? " · " + router.model : "") + (router.firmware ? " · " + router.firmware : "") + (router.management ? " · панель доступна" : " · панель не подтверждена") : "";
  const check = byId("startup-check");
  if (check.textContent !== result + routerLine) check.textContent = result + routerLine;
  const message = [
    actionError,
    !connected ? "Подключение к Wi Fi потеряно. Проверь окно запуска." :
      stalled ? "Окно сервера отвечает, но замеры остановились. Проверь окно запуска Wi Fi." :
      state?.issue || (health?.scan === "stale" ? "Windows давно не возвращала свежие замеры. Нажми «Обновить»." : ""),
    connected && !stalled ? state?.storage : "",
  ].filter(Boolean).join(" ");
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
  const scanBlocked = state.health?.scan === "blocked";
  const emptyText = scanBlocked ? "Сканирование ограничено Windows." :
    state.scanning ? "Ожидание сканирования." : "Видимых точек нет.";
  const pointSignature = state.points.length ? JSON.stringify(state.points) : emptyText;
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
      const empty = child("td", emptyText, "empty");
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

function selectedFrame() {
  return spectrumFrames.find((candidate) => candidate.key === frameKey) || air.frame();
}

function mapPoints() {
  return selectedFrame()?.points || state?.points || [];
}

function pointCaption(point) {
  return point.name + " · канал " + point.channel + " · " + point.frequency + " МГц · " + point.signalText +
    " · " + (point.measured ? "" : "≈") + point.width + " МГц" +
    (point.generation && point.generation !== "unverified" ? " · " + point.generation : "") +
    (point.rsnVersion != null ? " · RSN v" + point.rsnVersion : "") +
    (point.unknownIeCount ? " · других IE " + point.unknownIeCount : "") +
    (point.stale ? " · " + (point.observedAt ? "видели в " + new Date(point.observedAt).toLocaleTimeString("ru-RU") : "старый замер") : "");
}

function renderMapControls() {
  const archive = selectedFrame();
  const selectedPoint = mapPoints().find((point) => point.id === pinnedPoint);
  byId("point-focus").textContent = selectedPoint ? pointCaption(selectedPoint) :
    pinnedPoint ? "Выбранной точки нет в этом снимке" : "Выбери точку на карте";
  byId("clear-point").hidden = !pinnedPoint;
  historyPosition.disabled = spectrumFrames.length === 0;
  historyPosition.max = String(spectrumFrames.length);
  const position = spectrumFrames.indexOf(archive);
  historyPosition.value = String(position >= 0 ? position : spectrumFrames.length);
  byId("history-time").textContent = archive ?
    (archive.source === "android" ? "Android · " : "") +
      (archive.source === "android" ? new Date(archive.at).toLocaleString("ru-RU") : new Date(archive.at).toLocaleTimeString("ru-RU")) :
    "Сейчас";
  historyPosition.setAttribute("aria-valuetext", byId("history-time").textContent);
  byId("go-live").hidden = !archive;
  air.showControls(archive, mapPoints());
  for (const band of sources) {
    const ownPoint = archive ? archive.points.filter((point) => point.own && point.band === band.key)
      .sort((a, b) => b.signal - a.signal)[0] : null;
    const current = state?.bands.find((item) => item.key === band.key);
    const channel = archive ? ownPoint?.channel : current?.channel;
    const width = archive ? ownPoint?.width : current?.width;
    byId("band-" + band.suffix).textContent = channel ?
      "Канал " + channel + (width ? " / " + width + " МГц" : "") : "Своя сеть не видна";
  }
}

async function refreshSpectrum(scanAt) {
  if (latestSpectrumScan === scanAt || loadingSpectrum) return;
  loadingSpectrum = true;
  try {
    const response = await fetch("/api/spectrum", { cache: "no-store", signal: AbortSignal.timeout(2600) });
    if (!response.ok) return;
    const frames = await response.json();
    if (!Array.isArray(frames)) return;
    latestSpectrumScan = scanAt;
    windowsFrames = frames;
    updateSpectrum();
  } catch {
    // The live plot remains available while the archive is unavailable.
  } finally {
    loadingSpectrum = false;
  }
}

function updateSpectrum() {
  const frames = [...windowsFrames.slice(-(16 - phoneFrames.length)), ...phoneFrames]
    .sort((first, second) => first.at - second.at);
  if (frames.at(-1)?.key !== spectrumFrames.at(-1)?.key && !reduceMotion.matches) revealAt = performance.now();
  spectrumFrames = frames;
  air.readArchive(frames);
  if (frameKey && !frames.some((item) => item.key === frameKey)) frameKey = null;
  frameBins.clear();
  renderMapControls();
  scheduleDraw();
}

function parsePhoneScan(report, home) {
  const lines = report.trim().split(/\r?\n/);
  if (!lines[0]?.startsWith("Time Stamp|SSID|BSSID|Strength|Primary Channel|Primary Frequency|")) {
    throw new Error("Вставь текст из пункта «Экспорт» приложения WiFiAnalyzer от VREM.");
  }
  const rows = lines.slice(1);
  const frame = { source: "android", at: 0, points: [] };
  const byPoint = new Map();
  for (const row of rows.slice(0, 2000)) {
    const match = /^(\d{4}\/\d{2}\/\d{2}-\d{2}:\d{2}:\d{2})\|(.*?)\|((?:[a-f\d]{2}:){5}[a-f\d]{2})\|(-?\d+)dBm\|(\d+)\|(\d+)MHz\|[^|]*\|(\d+)MHz\|(\d+)MHz(?: |\|)/i.exec(row);
    if (!match) continue;
    const [, stamp, name, address, strength, primaryChannel, primaryFrequency, centerFrequency, widthText] = match;
    const at = Date.parse(stamp.replaceAll("/", "-").replace(/-(?=\d{2}:)/, "T"));
    const channel = Number(primaryChannel);
    const frequency = Number(primaryFrequency);
    const center = Number(centerFrequency);
    const width = Number(widthText);
    const rssi = Number(strength);
    const band = channel >= 1 && channel <= 14 && frequency === (channel === 14 ? 2484 : 2407 + 5 * channel) ? "2.4" :
      channel >= 32 && channel <= 177 && frequency === 5000 + 5 * channel ? "5" : null;
    if (!band || !Number.isFinite(at) || rssi < -127 || rssi >= 0) continue;
    // Exports expose one center frequency. Use the primary 20 MHz if width cannot be inferred.
    const measured = (band === "5" ? [20, 40, 80, 160] : [20, 40]).includes(width) &&
      Math.abs(frequency - center) <= width / 2 - 10;
    const assumedWidth = measured ? width : 20;
    const midpoint = measured ? center : frequency;
    const id = address.toLowerCase() + "/" + band;
    if (frame.at && frame.at !== at) throw new Error("Вставь один экспорт за раз.");
    frame.at = at;
    const point = {
      id, name: name || "Скрытая сеть", band, channel, frequency, rssi, observedAt: at,
      signal: Math.round(Math.min(100, Math.max(1, 2 * (rssi + 100)))),
      signalText: rssi + " дБм", width: assumedWidth, measured,
      segments: [{ Left: midpoint - assumedWidth / 2, Right: midpoint + assumedWidth / 2 }],
      own: Boolean(home && name === home), stale: false, tracked: false,
    };
    if (!byPoint.has(id) || byPoint.get(id).rssi < rssi) byPoint.set(id, point);
  }
  if (!byPoint.size) throw new Error("В экспорте нет читаемых точек 2,4 или 5 ГГц.");
  frame.key = "android/" + frame.at;
  frame.points = [...byPoint.values()].sort((first, second) => second.rssi - first.rssi).slice(0, 500);
  return frame;
}

function chooseFrame(key) {
  air.cancel(Boolean(key));
  frameKey = key;
  renderMapControls();
  scheduleDraw();
}

function choosePoint(id) {
  pinnedPoint = id;
  renderMapControls();
  scheduleDraw();
}

function renderState(next) {
  const previous = state?.points?.find((point) => point.id === next.tracked && !point.stale);
  const current = next.points.find((point) => point.id === next.tracked && !point.stale);
  if (previous && current && previous.channel !== current.channel && !reduceMotion.matches) {
    trail = { previous, current, at: performance.now() };
  }
  if (next.scanAt && next.scanAt !== state?.scanAt && !reduceMotion.matches) {
    document.querySelector(".brand .glyph")?.animate?.(
      [{ opacity: .45 }, { opacity: 1, offset: .36 }, { opacity: .85 }],
      { duration: 720, easing: "ease-out" }
    );
  }
  state = next;
  air.readState(next);
  if (lastStateTime !== next.now) receivedAt = performance.now();
  lastStateTime = next.now;
  connected = true;
  if (state.home !== stamp) {
    if (document.activeElement !== homeField) homeField.value = state.home;
    stamp = state.home;
  }
  renderStatus();
  state.bands.forEach((band, index) => {
    const suffix = sources[index].suffix;
    byId("advice-" + suffix).textContent = band.advice;
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
  const router = state.router || {};
  const telemetry = state.routerTelemetry;
  byId("router-source").textContent = state.source || "Windows / шлюз";
  byId("router-identity").textContent = "Шлюз Wi-Fi: " + (router.address || "не определён") +
    " · " + (router.reachable ? "отвечает на контрольные запросы" : "доступность не подтверждена");
  byId("router-capabilities").textContent = "Сканирование: Windows WLAN / netsh. Роутер не требует специальной прошивки или API.";
  const airtime = telemetry?.airtime || [];
  byId("router-airtime").textContent = airtime.length ?
    "Показатели из импорта (не проверены): " + airtime.map(item => item.band + " ГГц, канал " + item.channel + " · " + item.busyPercent + "%").join("; ") :
    "Измеренная загрузка эфира: недоступна. Показанные пересечения — математическая оценка.";
  byId("router-automation").textContent = state.automation?.reason || "Автоматическое управление недоступно.";
  for (const [band, suffix] of [["2.4", "24"], ["5", "5"]]) {
    const evidence = state.evidence?.[band];
    byId("evidence-" + suffix).textContent = (band === "2.4" ? "2,4" : "5") + " ГГц: " +
      (evidence?.reasons?.join(" · ") || "Ожидание измерений");
  }
  const ranking = ["2.4", "5"].flatMap(band => {
    const rows = state.quality?.[band] || [];
    const top = rows.slice(0, 3).map(row => {
      const q = row.measuredQuality;
      return row.channel + " (" + row.width + " МГц): оценка " + row.historicalRank.toFixed(1) +
        (q?.comparable ? ", замеры " + q.badPercent + "% сбоев, p90 " + q.p90 + " мс" :
        ", реальных испытаний канала недостаточно");
    });
    return [band + " ГГц: " + (top.join("; ") || "нет подтверждённых каналов")];
  });
  byId("router-ranking").textContent = ranking.join(" · ");
  const scanSummary = state.neighborScan;
  const summaryBands = (scanSummary?.bands || []).map(band => band.band + " ГГц: " +
    band.neighbors + " соседних точек · " + (band.channels || []).map(ch =>
      ch.channel + " (" + ch.networks + ")").join(", "));
  byId("neighbor-scan-summary").textContent = scanSummary ?
    "Соседние Wi-Fi-сети: " + scanSummary.neighborCount + " · " +
    summaryBands.join(" | ") + ". " + scanSummary.explanation :
    "Ожидание сканирования.";
  const v3 = state.radioV3 || {};
  byId("v3-beacon").textContent = "Beacon IE: скрытых SSID " + (v3.hidden ?? 0) +
    ", HE/Wi-Fi 6 " + (v3.he ?? 0) + ", EHT/Wi-Fi 7 " + (v3.eht ?? 0) +
    ", P2P IE " + (v3.p2pAdvertised ?? 0) + ". Это объявленные возможности, а не измерение скорости.";
  const direct = state.directInventory || {};
  byId("v3-direct").textContent = "Wi-Fi Direct: локальных виртуальных адаптеров " +
    (direct.virtualAdapters?.length || 0) + "; поиск соседних Direct-устройств не выполняется без поддерживаемого интерфейса.";
  const cap = state.captureSupport || {};
  byId("v3-monitor").textContent = "Monitor Capture: " + (cap.npcapPresent ? "Npcap обнаружен" : "Npcap не обнаружен") +
    "; захват отключён, поддержка драйвером не подтверждена. PCAP доступен для офлайн-анализа.";
  const wlanEvents = state.wlanEvents || {};
  byId("v3-events").textContent = wlanEvents.status === "read-only" ?
    "WLAN AutoConfig, последние 12 часов: событий " + (wlanEvents.count || 0) +
    " · " + (wlanEvents.events || []).map(e => "ID " + e.id + " (" + e.at + ")").join(", ") :
    "Журнал WLAN: нет доступных событий или Windows ограничила чтение.";
  byId("v3-roam").textContent = v3.recentRoams?.length ?
    "Роуминг: " + v3.recentRoams.map(r => r.from + " → " + r.to +
       " · локальных проблем рядом " + r.localProblemsNearby + " (причина не установлена)").join("; ") :
    "Роуминг: подтверждённых переключений своего BSSID пока нет.";
  byId("v3-research").textContent = state.researchV3?.items?.length ?
    "Гипотезы: " + state.researchV3.items.join(" ") :
    "Гипотезы: ещё недостаточно сопоставимых измерений.";
  const evolution = state.neighborEvolution || {};
  byId("neighbor-evolution").textContent = evolution.status === "observed" ?
    "Наблюдений: " + evolution.completeSurveys + " · устойчивых точек: " + evolution.stable +
    " · впервые замеченных: " + evolution.new + " · проверяются: " + evolution.tentative +
    " · не замечены повторно: " + evolution.notObserved + ". " + evolution.explanation :
    (evolution.explanation || "Пока недостаточно завершённых сканирований.");
  const guide = state.permissionGuidance || {};
  byId("scan-permissions").textContent = guide.status === "scan-restricted" ?
    "Ограничение Windows: " + guide.reason + " " + (guide.steps || []).join(" ") :
    "Сканирование: подтверждённых ограничений разрешений не обнаружено.";
  const picker = byId("wifi-adapter-select");
  const options = state.adapters || [];
  const optionSignature = JSON.stringify(options.map(a => [a.id,a.name]));
  if (picker.dataset.signature !== optionSignature) {
    picker.dataset.signature = optionSignature;
    picker.replaceChildren(new Option("Автоматический выбор", ""));
    for (const a of options) picker.add(new Option((a.name || "Wi-Fi") + " · " + (a.status || "неизвестно"), a.id));
  }
  if (document.activeElement !== picker) picker.value = state.selectedAdapter || "";
  const recovery = state.recovery || {};
  byId("scan-recovery").textContent = "Автовосстановление: " +
    (recovery.category === "unknown" ? "причина не определена" : recovery.category) +
    " · последовательных ошибок " + (recovery.failures || 0) +
    " · при блокировке повтор активного сканирования не чаще раза в 120 секунд.";
  byId("scan-bands").textContent = "Наблюдаемые диапазоны: " +
    (state.hardwareBands || []).map(b => b.band + " ГГц: " + b.observed + " точек").join(" · ") +
    ". Отсутствие точек не доказывает отсутствие аппаратной поддержки.";
  const startup = state.startupChecks || {};
  byId("scan-startup").textContent = "Самотест: код " + (startup.codePresent ? "OK" : "неизвестно") +
    " · интерфейс " + (startup.webFilesPresent ? "OK" : "нет") +
    " · SQLite " + (startup.sqliteIntegrity ? "OK" : "недоступна") +
    " · адаптеров " + (startup.wifiAdapters ?? "—");
  const perf = state.performance || {};
  byId("scan-performance").textContent = "Процесс: память " + (perf.processWorkingSetMb ?? "—") +
    " МБ · CPU накопленно " + (perf.cpuSeconds ?? "—") + " сек" +
    " · скан " + (perf.scanElapsedMs ?? 0) + " мс";
  const research = state.researchConfidence || {};
  byId("scan-memory").textContent = "Долговременная память: " +
    (state.longMemory?.length || 0) + " сохранённых суточных рядов · оценка " +
    (research.level || "низкая") + " · независимых сканов " + (research.independentScans ?? 0);
  byId("scan-backup").textContent = "Резервирование SQLite: " +
    (state.backup?.status || "ожидание") + (state.backup?.note ? " · " + state.backup.note : "") +
    " · локальный отчёт " + (state.report?.at ? new Date(state.report.at).toLocaleString("ru-RU") : "ожидание");
  byId("scan-investigation").textContent = "Расследования: " + (research.incidents?.length || 0) +
    " · аномалий BSSID " + (research.anomalies?.length || 0) +
    " · источник " + (research.source || "не подтверждён") +
    " · выводы требуют независимых проб.";
  byId("scan-ssid-variation").textContent = state.ssidVariations?.length ?
    "Одинаковые SSID с разными объявлениями (не доказательство подмены): " +
    state.ssidVariations.map(v => v.ssid + " · " + v.accessPoints + " BSSID").join("; ") :
    "Изменений объявленных параметров под одним SSID не обнаружено или данных недостаточно.";
  byId("scan-alerts").textContent = research.alerts?.length ?
    "Диагностика: " + research.alerts.slice(0,3).map(a => a.kind + " · " +
      new Date(a.at).toLocaleTimeString("ru-RU")).join("; ") :
    "Уведомления: значимых событий пока нет.";
  const adapter = state.adapterSummary || {};
  byId("scan-adapter").textContent = "Wi-Fi-адаптер: " + (adapter.name || "не определён") +
    " · " + (adapter.description || "модель не определена") +
    " · драйвер: " + (adapter.driver === "not-verified" ? "не подтверждён" : adapter.driver || "неизвестно") +
    " · поддерживаемые диапазоны: не подтверждены";
  byId("scan-confidence").textContent = "Достоверность снимка: " + ({
    observed:"завершённый Windows WLAN", "cached-or-incomplete":"кэш / неполный скан",
    "unverified-cache":"netsh, свежесть кэша неизвестна",
    "stale-or-missing":"снимок устарел или отсутствует",unverified:"не подтверждена"
  }[state.scanConfidence] || "ожидание");
  byId("scan-interference").textContent = "Соседние сигналы (оценка, не загрузка эфира): " +
    (state.interference || []).map(b => b.band + " ГГц: " +
      (b.strongest || []).map(p => "канал " + p.channel + " / " + p.signal + "%").join(", ")).join(" · ");
  byId("neighbor-stability").textContent = "Динамика сети: нестабильных точек " +
    (evolution.volatile || 0) + " · " +
    (evolution.strongest || []).map(p => (p.name || "Скрытая сеть") +
      " (средний сигнал " + p.meanSignal + "%, RSSI " + (p.averageRssi ?? "—") + " дБм, " + p.sightings + " наблюдений)").join("; ");
  const changeLabels = { "new-observation": "новая точка", "channel-shift": "смена наблюдаемого канала", "not-observed": "отсутствует в двух снимках" };
  byId("neighbor-changes").textContent = evolution.changes?.length ?
    "Изменения за последний час: " + evolution.changes.map(e =>
      (changeLabels[e.type] || "наблюдение") + " · " + (e.name || "скрытая сеть") +
      " · " + e.band + " ГГц" + (e.from != null ? " / " + e.from : "") +
      (e.to != null ? " → " + e.to : "")).join("; ") :
    "Подтверждённых изменений соседних точек пока нет.";
  byId("router-source-evidence").textContent = state.sourceEvidence?.label || "Источник радиоэфира не определён.";
  byId("router-safety").textContent = state.automation?.reason || "Автоматические изменения отключены.";
  for (const [band, suffix] of [["2.4", "24"], ["5", "5"]]) {
    const guard = state.recommendationGuards?.[band];
    const confidence = state.recommendationConfidence?.[band];
    byId("router-guard-" + suffix).textContent = band + " ГГц · " +
      (confidence?.eligible ? "Кандидат для ручной проверки" : "Только наблюдение") + ": " +
      (guard?.reasons?.join(" · ") || confidence?.reason || "Ожидание измерений");
  }
  const repeated = state.repeatedIssues || [];
  byId("router-patterns").textContent = repeated.length ?
    "Повторения по часам UTC: " + repeated.map(p => p.band + " ГГц / " + p.channel +
      " · " + p.hourUtc + ":00 · " + p.days + " дня").join("; ") :
    "Повторяющихся проблем по одинаковым часам разных дней не выявлено или недостаточно данных.";
  const trend = state.trend || {};
  byId("router-trend").textContent = "Качество связи: " +
    ({ worsening: "рост сбоев", improving: "снижение сбоев", "stable-or-unclear": "существенного изменения не выявлено",
       insufficient: "мало измерений", unavailable: "нет данных" }[trend.status] || "ожидание") +
    " · " + (trend.reason || "Сначала собери измерения.");
  const hourly = state.hourlyEfficiency || [];
  byId("router-hourly").textContent = hourly.length ? hourly.slice(0, 24).map(r =>
    r.hourUtc + " UTC · " + r.band + " ГГц / " + r.channel + " (" + r.width + " МГц) · " +
    r.samples + " проб · " + r.badPercent + "% сбоев · " + r.lossPercent + "% потерь · " +
    (r.averageMs == null ? "нет задержки" : r.averageMs + " мс")).join("\n") :
    "Пока недостаточно сохранённых измерений. Результат основан на SQLite.";
  const density = state.hourlyNeighbors || [];
  byId("neighbor-hourly").textContent = density.length ? density.slice(0,16).map(r =>
    r.hourUtc + " UTC · " + r.band + " ГГц · " + r.scans +
    " сканов · соседей в среднем " + r.averageNeighbors +
    " (макс. " + r.maxNeighbors + ")" +
    (r.localBadPercent == null ? " · локальных проб недостаточно" :
      " · локальных плохих проб " + r.localBadPercent + "%") +
    " · причинная связь не установлена").join("\\n") :
    "Нужны как минимум два сохранённых скана за час. Данные из SQLite.";
  const trials = state.recentTrials || [];
  byId("router-trials").textContent = trials.length ? trials.map(r =>
    new Date(r.at).toLocaleString("ru-RU") + " · " + r.old + " → " + r.new +
    " · " + r.pairs + " пар · сбои " + r.beforeBad + " → " + r.afterBad +
    " · " + ({ improved: "улучшение", worse: "ухудшение", unclear: "неясно", insufficient: "мало данных" }[r.outcome] || "нет данных")
  ).join("\n") : "Сравнений пока нет. После ручного изменения канала история появится автоматически.";
  renderHeat();
  renderLists();
  renderMapControls();
  void refreshSpectrum(state.scanAt);
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
  const archive = selectedFrame();
  const visible = mapPoints().filter((point) => point.band === band.key);
  const points = air.renderedPoints(visible, archive, now).filter((point) => point.band === band.key);
  const mode = air.describeBand(band, archive);
  const currentOwnId = state?.bands.find((item) => item.key === band.key)?.ownId;
  const local = archive ? points.filter((point) => point.own).sort((a, b) => b.signal - a.signal)[0] :
    points.find((point) => point.id === currentOwnId && !point.stale);
  const focused = visible.find((point) => point.id === pinnedPoint);
  const emphasized = mode.xray && local ? (point) => point.own ||
    (!point.stale && AirMap.overlaps(local, point) &&
      (!mode.xray.mhz || point.segments.some((segment) => AirMap.inSegment(segment, mode.xray.mhz)))) : null;
  const geometry = (point, segment, delta = 0) => makeArc(
    position(segment.Left + delta, band, width),
    position(segment.Right + delta, band, width),
    floor, Math.max(5, point.signal / 100 * space)
  );
  const localPaths = local ? local.segments.map((segment) => geometry(local, segment)) : [];
  const gridTint = context.createLinearGradient(14, 0, width - 14, 0);
  gridTint.addColorStop(0, "#3c443536");
  gridTint.addColorStop(.48, "#59644983");
  gridTint.addColorStop(1, "#3c443536");
  context.font = '10px "Consolas", monospace';
  context.lineWidth = 1;
  context.strokeStyle = gridTint;
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
    context.save();
    context.setLineDash([2, 5]);
    context.globalAlpha = .37;
    context.beginPath();
    context.moveTo(x, 10);
    context.lineTo(x, floor);
    context.stroke();
    context.restore();
    previousLabel = x;
  }

  if (points.length === 0) {
    context.font = '12px "Segoe UI", sans-serif';
    const message = state?.health?.scan === "blocked" ? "Сканирование недоступно" :
      state?.scanning ? "Сканирование эфира" : "Видимых точек пока нет";
    context.fillText(message, width / 2, floor / 2);
  }

  for (const point of [...points].sort((a, b) => Number(a.own) - Number(b.own) || a.signal - b.signal)) {
    const moving = !archive && trail?.current.id === point.id && now - trail.at < 2200;
    const active = focused?.id === point.id;
    const accent = active || point.own;
    const progress = moving ? Math.min(1, (now - trail.at) / 690) : 1;
    const shift = moving ? (trail.previous.frequency - point.frequency) * (1 - progress) ** 3 : point.shift || 0;
    const color = point.own ? palette.gold : moving || point.tracked ? palette.trail : palette.blue;
    point.segments.forEach((segment, index) => {
      const path = geometry(point, segment, index === 0 ? shift : 0);
      const fill = context.createLinearGradient(0, 5, 0, floor);
      fill.addColorStop(0, color + (accent ? "68" : "36"));
      fill.addColorStop(.68, color + (accent ? "2a" : "13"));
      fill.addColorStop(1, color + "08");
      const opacity = point.stale ? .27 : emphasized && !emphasized(point) ? .14 : focused && !active && !point.own ? .44 : 1;
      context.globalAlpha = opacity * (point.fade ?? 1);
      context.fillStyle = fill;
      context.fill(path);
      if (!point.own && !point.stale && progress === 1 && !shift && (!emphasized || emphasized(point))) {
        for (const ownPath of localPaths) {
          context.save();
          context.clip(ownPath);
          context.fillStyle = palette.glow + "33";
          context.fill(path);
          context.fillStyle = overlapPattern(context);
          context.fill(path);
          context.restore();
        }
      }
      context.save();
      context.lineWidth = accent || point.tracked ? 1.8 : 1;
      if (accent) {
        context.shadowColor = color + "b0";
        context.shadowBlur = active ? 20 : 12;
      }
      context.strokeStyle = color;
      context.stroke(path);
      context.restore();
      if (point.priorSignal != null && point.effectAlpha > 0) {
        context.save();
        context.globalAlpha *= point.effectAlpha * .33;
        context.setLineDash([3, 3]);
        context.strokeStyle = color;
        context.stroke(makeArc(position(segment.Left, band, width), position(segment.Right, band, width), floor,
          Math.max(5, point.priorSignal / 100 * space)));
        context.restore();
      }
    });
    const primary = position(point.frequency + shift, band, width);
    context.fillStyle = color;
    context.fillRect(primary - .75, floor - 4, 1.5, 7);
    if (point.own) AirMap.markRouter(context, primary, floor - 8);
    else if (accent || point.tracked || point.fade < 1) {
      context.save();
      context.strokeStyle = color;
      context.fillStyle = "#18201a";
      AirMap.hexagon(context, primary, floor - Math.max(8, point.signal / 100 * space), 4.5);
      context.fill();
      context.stroke();
      context.restore();
    }
    if (point.effectAlpha > 0 && (point.deltaDb || point.oldChannel) && (point.own || point.tracked || active)) {
      context.save();
      context.textAlign = "center";
      context.globalAlpha *= point.effectAlpha;
      const note = point.oldChannel ? point.oldChannel + " → " + point.channel :
        (point.deltaDb > 0 ? "+" : "") + point.deltaDb + " дБ";
      context.fillText(note, primary, Math.max(12, floor - point.signal / 100 * space - 8));
      context.restore();
    }
    context.globalAlpha = 1;
  }
  air.drawBandOverlay({
    context, band, width, floor, space, visible, own: local, selected: archive, now,
    position: (mhz) => position(mhz, band, width), arc: makeArc,
  });
  if (focused) {
    const x = position(focused.frequency, band, width);
    const tint = focused.own ? palette.gold : palette.blue;
    context.save();
    context.setLineDash([2, 3]);
    context.strokeStyle = tint + "a0";
    context.beginPath();
    context.moveTo(x, 11);
    context.lineTo(x, floor + 1);
    context.stroke();
    context.setLineDash([]);
    context.fillStyle = tint;
    context.beginPath();
    context.arc(x, floor, 3, 0, 2 * Math.PI);
    context.fill();
    context.restore();
  }
  if (!archive && trail?.current.band === band.key && now - trail.at < 2200) {
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

const receiverBins = 144;
const waterfallColors = ["#111a18", "#162b29", "#1d4241", "#28615b", "#408778", "#78ad91", "#d2ac6f", "#f0c373"];

function scanBins(snapshot, band) {
  if (!frameBins.has(snapshot.key)) frameBins.set(snapshot.key, {});
  const cached = frameBins.get(snapshot.key);
  if (cached[band.key]) return cached[band.key];
  const bins = new Uint8Array(receiverBins);
  const span = band.max - band.min;
  for (const point of snapshot.points) {
    if (point.band !== band.key) continue;
    for (const segment of point.segments) {
      const left = Math.max(0, Math.floor((segment.Left - band.min) / span * receiverBins));
      const right = Math.min(receiverBins, Math.ceil((segment.Right - band.min) / span * receiverBins));
      const center = (segment.Left + segment.Right) / 2;
      const radius = (segment.Right - segment.Left) / 2;
      for (let i = left; i < right; i++) {
        const frequency = band.min + (i + .5) / receiverBins * span;
        const shape = Math.max(0, 1 - Math.abs(frequency - center) / radius);
        const signal = Math.round(Math.min(7, point.signal / 100 * 7 * Math.sqrt(shape)));
        bins[i] = Math.max(bins[i], signal);
      }
    }
  }
  cached[band.key] = bins;
  return bins;
}

function drawWaterfall(band, now) {
  const canvas = byId("waterfall-" + band.suffix);
  const activeKey = selectedFrame()?.key;
  const changing = now - revealAt < 570;
  const signature = [canvas.clientWidth, canvas.clientHeight, devicePixelRatio, activeKey, ...spectrumFrames.map((item) => item.key)].join("|");
  if (!changing && canvas.dataset.frame === signature) return;
  canvas.dataset.frame = changing ? "" : signature;
  const { context, width, height } = viewport(canvas);
  const left = 14;
  const usable = width - 2 * left;
  if (!spectrumFrames.length) {
    context.fillStyle = palette.text;
    context.font = '11px "Segoe UI", sans-serif';
    context.fillText("История появится после сканирования", left, 19);
    return;
  }
  const binsWidth = usable / receiverBins;
  const labelHeight = 13;
  const rowHeight = (height - labelHeight - 2) / 16;
  spectrumFrames.forEach((snapshot, index) => {
    const y = 2 + (16 - spectrumFrames.length + index) * rowHeight;
    const bins = scanBins(snapshot, band);
    const latest = index === spectrumFrames.length - 1;
    const reveal = latest ? Math.min(1, Math.max(0, (now - revealAt) / 530)) : 1;
    const limit = Math.ceil(receiverBins * reveal);
    for (let i = 0; i < receiverBins; i++) {
      context.fillStyle = waterfallColors[i < limit ? bins[i] : 0];
      context.fillRect(left + i * binsWidth, y, binsWidth + .25, Math.max(1, rowHeight - .32));
    }
    if (snapshot.key === activeKey) {
      context.strokeStyle = palette.gold;
      context.lineWidth = 1;
      context.strokeRect(left - .5, y - .15, usable + 1, rowHeight);
    }
  });
  context.fillStyle = palette.text;
  context.font = '9px "Consolas", monospace';
  context.textAlign = "left";
  const time = (snapshot) => new Date(snapshot.at).toLocaleTimeString("ru-RU", { hour: "2-digit", minute: "2-digit" });
  const range = spectrumFrames.length > 1 ?
    time(spectrumFrames[0]) + " → " + time(spectrumFrames.at(-1)) + " · сверху вниз" :
    time(spectrumFrames[0]);
  context.fillText(range, left, height - 1);
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
  const incident = air.eventTime();
  if (incident && currentTime - incident >= 0 && currentTime - incident <= 60000) {
    const x = right - usable * (currentTime - incident) / 60000;
    context.save();
    context.strokeStyle = "#ff9c549a";
    context.setLineDash([3, 3]);
    context.beginPath();
    context.moveTo(x, 7);
    context.lineTo(x, base);
    context.stroke();
    context.restore();
  }
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
        context.arc(x, y, 3.6, .4, 2.72);
        context.moveTo(x - 3.4, y - 1.1);
        context.arc(x, y, 3.6, 3.55, 5.89);
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
    for (const band of sources) {
      drawBand(band, now);
      drawWaterfall(band, now);
    }
    if (byId("archive-view").open) air.drawVolumes(now, selectedFrame(), pinnedPoint || state?.tracked);
    const pulse = drawLatency(now);
    const story = air.tick(now);
    if (trail && now - trail.at >= 2200) trail = null;
    if (trail || pulse || story || air.animating(now) || now - revealAt < 550) scheduleDraw();
  });
}

for (const band of sources) {
  const canvas = byId("spectrum-" + band.suffix);
  const waterfall = byId("waterfall-" + band.suffix);
  const tooltip = byId("tip-" + band.suffix);
  function nearbyPoint(x) {
    const width = canvas.clientWidth;
    return mapPoints().filter((point) => point.band === band.key)
      .map((point) => ({ point, distance: Math.abs(x - position(point.frequency, band, width)) }))
      .filter((item) => item.distance <= 16)
      .sort((a, b) => a.distance - b.distance || Number(a.point.stale) - Number(b.point.stale) || b.point.signal - a.point.signal)[0]?.point;
  }

  canvas.addEventListener("pointermove", (event) => {
    const point = nearbyPoint(event.offsetX);
    tooltip.hidden = !point;
    if (point) tooltip.textContent = pointCaption(point);
  });
  canvas.addEventListener("pointerleave", () => { tooltip.hidden = true; });
  canvas.addEventListener("click", (event) => {
    const visible = mapPoints().filter((point) => point.band === band.key && !point.stale);
    const mhz = band.min + (event.offsetX - 14) / (canvas.clientWidth - 28) * (band.max - band.min);
    const floor = canvas.clientHeight - 23;
    const onArc = (point) => point.segments.some((segment) => {
      if (!AirMap.inSegment(segment, mhz)) return false;
      const ratio = (mhz - segment.Left) / Math.max(1, segment.Right - segment.Left);
      const rise = (floor - 10) * point.signal / 100 * Math.max(0, Math.sin(ratio * Math.PI)) ** 1.6;
      return event.offsetY < floor - 8 && event.offsetY >= floor - rise;
    });
    if (visible.some((point) => point.own && onArc(point)) && visible.some((point) => !point.own && onArc(point))) {
      air.activateXray(band.key, mhz);
      return;
    }
    const point = nearbyPoint(event.offsetX);
    if (point) choosePoint(pinnedPoint === point.id ? null : point.id);
  });
  canvas.addEventListener("keydown", (event) => {
    if (event.key === "Escape") {
      choosePoint(null);
      return;
    }
    if (!["ArrowLeft", "ArrowRight"].includes(event.key)) return;
    const points = mapPoints().filter((point) => point.band === band.key)
      .sort((a, b) => a.frequency - b.frequency || b.signal - a.signal);
    if (!points.length) return;
    event.preventDefault();
    const current = points.findIndex((point) => point.id === pinnedPoint);
    const shift = event.key === "ArrowLeft" ? -1 : 1;
    const index = current < 0 ? (shift > 0 ? 0 : points.length - 1) : (current + shift + points.length) % points.length;
    choosePoint(points[index].id);
  });
  waterfall.addEventListener("click", (event) => {
    const rowHeight = (waterfall.clientHeight - 15) / 16;
    const index = Math.floor((event.offsetY - 2) / rowHeight) - (16 - spectrumFrames.length);
    if (spectrumFrames[index]) chooseFrame(spectrumFrames[index].key);
  });
}

byId("latency").addEventListener("click", (event) => {
  const width = event.currentTarget.clientWidth;
  const ago = (width - 26 - event.offsetX) / (width - 52) * 60000;
  if (state && ago >= 0 && ago <= 60000) air.replayNearest(state.now + (performance.now() - receivedAt) - ago);
});
air.mount(selectedFrame);

historyPosition.addEventListener("input", () => {
  chooseFrame(spectrumFrames[Number(historyPosition.value)]?.key || null);
});
byId("go-live").addEventListener("click", () => chooseFrame(null));
byId("clear-point").addEventListener("click", () => choosePoint(null));
byId("archive-view").addEventListener("toggle", scheduleDraw);
addEventListener("resize", scheduleDraw);
scheduleDraw();

async function refresh() {
  try {
    const response = await fetch("/api/state", { cache: "no-store", signal: AbortSignal.timeout(2600) });
    if (!response.ok) throw new Error("state");
    const next = await response.json();
    if (!Number.isFinite(next.now) || !Array.isArray(next.bands) || next.bands.length !== 2) throw new Error("incomplete");
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

byId("phone-import").addEventListener("submit", (event) => {
  event.preventDefault();
  const input = byId("phone-report");
  const status = byId("phone-import-status");
  try {
    const home = byId("phone-home").value.trim() || state?.home;
    const snapshot = parsePhoneScan(input.value, home);
    phoneFrames = [...phoneFrames.filter((frame) => frame.key !== snapshot.key).slice(-7), snapshot];
    updateSpectrum();
    chooseFrame(snapshot.key);
    status.textContent = "Снимок открыт · точек: " + snapshot.points.length;
    input.value = "";
  } catch (error) {
    status.textContent = error.message;
  }
});

byId("refresh").addEventListener("click", () => command("refresh"));
byId("wifi-adapter-select").addEventListener("change", event => command("adapter", event.target.value));
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
