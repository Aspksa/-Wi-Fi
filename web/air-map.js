"use strict";

const AirMap = (() => {
  const svgNs = "http://www.w3.org/2000/svg";
  const el = (id) => document.getElementById(id);
  const motion = matchMedia("(prefers-reduced-motion: reduce)");
  const color = { gold: "#f1bd63", amber: "#ff9c54", cyan: "#89c9c9", green: "#8ed1a0", alert: "#ff8071" };
  const ageLimit = 45000;
  const timelineGap = 90000;

  function clock(at, seconds = false) {
    return new Date(at).toLocaleTimeString("ru-RU", {
      hour: "2-digit", minute: "2-digit", ...(seconds ? { second: "2-digit" } : {}),
    });
  }

  function svgIcon(name) {
    const svg = document.createElementNS(svgNs, "svg");
    const use = document.createElementNS(svgNs, "use");
    use.setAttribute("href", "#icon-" + name);
    svg.setAttribute("aria-hidden", "true");
    svg.append(use);
    return svg;
  }

  function radians(step) { return Math.PI / 3 * step; }
  function hexagon(ctx, x, y, radius) {
    ctx.beginPath();
    for (let step = 0; step < 6; step++) {
      const angle = radians(step);
      const px = x + radius * Math.cos(angle);
      const py = y + radius * Math.sin(angle);
      if (step === 0) ctx.moveTo(px, py);
      else ctx.lineTo(px, py);
    }
    ctx.closePath();
  }

  function inSegment(segment, mhz) {
    return segment.Left <= mhz && mhz <= segment.Right;
  }

  function overlaps(first, second) {
    return first.segments.some((a) => second.segments.some((b) => a.Left < b.Right && b.Left < a.Right));
  }

  function coverage(points, own, frequency) {
    if (!own || !own.segments.some((segment) => inSegment(segment, frequency))) return 0;
    return points.reduce((max, point) => {
      if (point.own || point.stale || !point.segments.some((segment) => inSegment(segment, frequency))) return max;
      return Math.max(max, point.signal / 100);
    }, 0);
  }

  function privatePoint(points, id) {
    return points.find((point) => point.id === id && !point.stale) ||
      points.filter((point) => point.own && !point.stale).sort((a, b) => b.signal - a.signal)[0];
  }

  function estimateProfile(points, band) {
    const bins = 72;
    const samples = Array.from({ length: bins + 1 }, () => 0);
    for (const point of points) {
      if (point.band !== band.key || point.stale) continue;
      for (const segment of point.segments) {
        const center = (segment.Left + segment.Right) / 2;
        const half = Math.max(1, (segment.Right - segment.Left) / 2);
        const scale = bins / (band.max - band.min);
        const start = Math.max(0, Math.floor((segment.Left - band.min) * scale));
        const stop = Math.min(bins, Math.ceil((segment.Right - band.min) * scale));
        for (let index = start; index <= stop; index++) {
          const mhz = band.min + index / scale;
          const shape = Math.max(0, 1 - ((mhz - center) / half) ** 2);
          samples[index] = Math.max(samples[index], Math.sqrt(shape) * point.signal / 100);
        }
      }
    }
    return samples;
  }

  function markRouter(ctx, x, y, opacity = 1) {
    ctx.save();
    ctx.globalAlpha *= opacity;
    ctx.strokeStyle = color.gold;
    ctx.fillStyle = "#191a12";
    ctx.lineWidth = 1.2;
    ctx.fillRect(x - 6, y - 3, 12, 5);
    ctx.strokeRect(x - 6, y - 3, 12, 5);
    ctx.beginPath();
    ctx.moveTo(x - 4, y - 3);
    ctx.lineTo(x - 4, y - 8);
    ctx.moveTo(x + 4, y - 3);
    ctx.lineTo(x + 4, y - 8);
    ctx.stroke();
    ctx.beginPath();
    ctx.arc(x, y - 4, 7, -2.35, -.79);
    ctx.stroke();
    ctx.restore();
  }

  function markLoss(ctx, x, y, radius, alpha) {
    ctx.save();
    ctx.globalAlpha *= alpha;
    ctx.strokeStyle = color.alert;
    ctx.lineWidth = 1.5;
    ctx.beginPath();
    ctx.arc(x, y, radius, .25, 2.9);
    ctx.moveTo(x - radius * .96, y - radius * .28);
    ctx.arc(x, y, radius, 3.42, 6.02);
    ctx.moveTo(x - radius * .42, y - radius * .42);
    ctx.lineTo(x + radius * .42, y + radius * .42);
    ctx.moveTo(x + radius * .42, y - radius * .42);
    ctx.lineTo(x - radius * .42, y + radius * .42);
    ctx.stroke();
    ctx.restore();
  }

  function linePath(ctx, vertices) {
    ctx.beginPath();
    vertices.forEach((point, index) => {
      if (index === 0) ctx.moveTo(point.x, point.y);
      else ctx.lineTo(point.x, point.y);
    });
  }

  function makeVolumeProjection(width, height, emphasis) {
    const front = height - 26;
    const horizontalSpace = width - 70;
    const lift = height * (.35 + emphasis * .08);
    return (x, depth, signal = 0) => ({
      x: 21 + depth * 37 + x * horizontalSpace * (1 - depth * .31),
      y: front - depth * height * .52 - signal * lift * (1 - depth * .28),
    });
  }

  function drawVolume(ctx, width, height, band, stored, latest, activeFrame, focus, incident, emphasis, getProfile) {
    if (width < 120 || height < 70) return;
    const layers = stored.length ? stored : latest && latest.points.length ? [latest] : [];
    const project = makeVolumeProjection(width, height, emphasis);
    ctx.strokeStyle = "#93a28742";
    ctx.lineWidth = 1;
    for (let value = 0; value <= 8; value++) {
      const x = value / 8;
      linePath(ctx, [project(x, 0), project(x, 1)]);
      ctx.stroke();
    }
    for (let value = 0; value <= 5; value++) {
      const depth = value / 5;
      linePath(ctx, [project(0, depth), project(1, depth)]);
      ctx.stroke();
    }
    ctx.font = '9px "Consolas", monospace';
    ctx.fillStyle = "#8f9c8d";
    ctx.textAlign = "left";
    const firstTick = project(0, 0);
    ctx.textAlign = "center";
    let labelX = -40;
    for (const channel of band.channels) {
      const mhz = (band.key === "5" ? 5000 : 2407) + 5 * channel;
      const pos = project((mhz - band.min) / (band.max - band.min), 0);
      if (pos.x - labelX < 21) continue;
      ctx.fillText(String(channel), pos.x, pos.y + 13);
      labelX = pos.x;
    }
    ctx.textAlign = "left";
    if (!layers.length) {
      ctx.fillText("Ожидание замеров", 24, 23);
      return;
    }

    const timeMax = layers.at(-1).at;
    const timeMin = layers[0].at;
    const visibleWindow = Math.max(30000, timeMax - timeMin);
    const depthOf = (at) => Math.min(1, Math.max(0, (timeMax - at) / visibleWindow));
    for (const layer of layers) {
      const profile = getProfile(layer, band);
      const depth = depthOf(layer.at);
      const isActive = layer.key === activeFrame?.key;
      const ridge = profile.map((signal, i) => project(i / (profile.length - 1), depth, signal));
      linePath(ctx, ridge);
      ctx.lineTo(project(1, depth).x, project(1, depth).y);
      ctx.lineTo(project(0, depth).x, project(0, depth).y);
      ctx.closePath();
      const tint = isActive ? "#f1bd6341" : layer === layers.at(-1) ? "#58b5aa32" : "#44877b1e";
      ctx.fillStyle = tint;
      ctx.fill();
      linePath(ctx, ridge);
      ctx.lineWidth = isActive ? 1.5 : .95;
      ctx.strokeStyle = isActive ? "#ffcc79dd" : layer === layers.at(-1) ? "#76cabc9e" : "#4c9c8d7a";
      ctx.stroke();
      if (isActive) {
        const p = project(0, depth);
        const q = project(1, depth);
        ctx.save();
        const topLeft = project(0, depth, 1.04);
        const topRight = project(1, depth, 1.04);
        const plane = ctx.createLinearGradient(0, topLeft.y, 0, p.y);
        plane.addColorStop(0, "#ffe0a107");
        plane.addColorStop(1, "#f1bd632b");
        linePath(ctx, [p, q, topRight, topLeft]);
        ctx.closePath();
        ctx.fillStyle = plane;
        ctx.fill();
        ctx.setLineDash([3, 3]);
        linePath(ctx, [p, q]);
        ctx.strokeStyle = color.gold;
        ctx.stroke();
        ctx.restore();
      }
    }

    function identityTrace(id, own, tone) {
      let previous = null;
      for (const layer of layers) {
        const points = layer.points.filter((point) => point.band === band.key);
        const point = own ? privatePoint(points, id) : points.find((item) => item.id === id && !item.stale);
        if (!point) { previous = null; continue; }
        const x = (point.frequency - band.min) / (band.max - band.min);
        const at = project(x, depthOf(layer.at), point.signal / 100);
        ctx.save();
        ctx.strokeStyle = tone;
        ctx.fillStyle = "#17231d";
        ctx.lineWidth = own ? 1.4 : 1;
        if (previous && layer.at - previous.at <= timelineGap && point.id === previous.id) {
          linePath(ctx, [previous, at]);
          ctx.stroke();
        }
        if (layer === layers.at(-1) || layer.key === activeFrame?.key) {
          if (own) markRouter(ctx, at.x, at.y);
          else { hexagon(ctx, at.x, at.y, 4); ctx.fill(); ctx.stroke(); }
        } else {
          ctx.fillStyle = tone + "bb";
          ctx.fillRect(at.x - 1, at.y - 1, 2, 2);
        }
        ctx.restore();
        previous = { ...at, at: layer.at, id: point.id };
      }
    }
    const currentOwn = privatePoint((activeFrame || latest)?.points.filter((point) => point.band === band.key) || []);
    identityTrace(currentOwn?.id, true, color.gold);
    if (focus) identityTrace(focus, false, color.cyan);

    if (incident?.band === band.key && incident.snapshot) {
      const layer = incident.snapshot;
      const own = privatePoint(layer.points.filter((point) => point.band === band.key));
      if (own) {
        const x = (own.frequency - band.min) / (band.max - band.min);
        const at = project(x, depthOf(layer.at), own.signal / 100);
        markLoss(ctx, at.x, at.y, 9 + emphasis * 4, .9);
      }
    }
    ctx.fillStyle = "#a9b2a0";
    ctx.font = '9px "Consolas", monospace';
    ctx.textAlign = "left";
    ctx.fillText("Каналы", firstTick.x, firstTick.y + 24);
    ctx.fillText(clock(timeMin), project(0, 1).x, Math.max(12, project(0, 1).y - 5));
  }

  function create({ bands, sizeCanvas, changed, resetView, chooseSlice }) {
    let state = null;
    let snapshots = [];
    let recentProbe = 0;
    let liveEpisodes = [];
    let currentStory = null;
    let storyStage = "";
    let storyMatchKey = null;
    let auto = true;
    try { auto = localStorage.getItem("wifi-air-auto") !== "off"; } catch { }
    let locked = false;
    let compare = { A: null, B: null };
    let comparisonSide = null;
    let preview = false;
    let xray = null;
    let lastEpisodeHtml = "";
    let observedKey = null;
    let lastPoints = new Map();
    let signalChanges = new Map();
    const profiles = new Map();

    function liveFrame() {
      return state?.scanAt && state.points.length ?
        { key: "live/" + state.scanAt, at: state.scanAt, points: state.points } : null;
    }

    function snapshotFor(at) {
      let nearest = null;
      let distance = Infinity;
      for (const item of snapshots) {
        const delta = Math.abs(item.at - at);
        if (Number.isFinite(item.at) && delta <= ageLimit && delta < distance) {
          nearest = item;
          distance = delta;
        }
      }
      return nearest;
    }

    function incidentList() {
      const saved = (state?.episodes || []).filter((item) => item && Number.isFinite(item.at));
      const live = liveEpisodes.filter((item) =>
        !saved.some((entry) => Math.abs(entry.at - item.at) <= 4000));
      return [...saved, ...live].sort((a, b) => b.at - a.at).slice(0, 8);
    }

    function incidentFrom(sample) {
      if (sample.scan) return null;
      if (sample.lost || sample.ms > 35) {
        return {
          route: "router", band: sample.band || null, at: sample.at,
          message: sample.lost ? "Роутер не ответил на контрольный запрос." :
            "Отклик роутера вырос до " + sample.ms + " мс.",
        };
      }
      if (sample.ms != null && (sample.wanLost || sample.wanMs > 180)) {
        return {
          route: "external", band: null, at: sample.at,
          message: sample.wanLost ? "Внешний адрес не ответил. Роутер отвечает." :
            "Отклик внешнего адреса вырос до " + sample.wanMs + " мс.",
        };
      }
      return null;
    }

    function begin(episode, passive = false) {
      preview = false;
      xray = null;
      compare = { A: null, B: null };
      comparisonSide = null;
      locked = false;
      resetView();
      currentStory = { episode, start: performance.now(), passive };
      storyStage = "";
      changed();
    }

    function readState(next) {
      state = next;
      const latest = next.now || Date.now();
      const first = recentProbe === 0;
      for (const sample of next.latency || []) {
        if (sample.at <= recentProbe) continue;
        recentProbe = sample.at;
        const entry = incidentFrom(sample);
        if (!entry) continue;
        const prior = liveEpisodes[0];
        if (prior && entry.at - prior.ended <= 8000 && prior.route === entry.route && prior.band === entry.band) {
          prior.ended = entry.at;
          prior.count++;
          continue;
        }
        entry.id = "live-" + entry.at;
        entry.ended = entry.at;
        entry.count = 1;
        liveEpisodes = [entry, ...liveEpisodes].slice(0, 8);
        if (auto && !locked && !currentStory && document.visibilityState !== "hidden" &&
            latest - entry.at <= (first ? 1600 : 3500)) begin(entry, true);
      }
      updateButtons();
      renderEpisodes();
    }

    function readArchive(frames) {
      snapshots = frames;
      const newest = frames.at(-1);
      if (newest && observedKey !== newest.key) {
        const previous = lastPoints;
        const points = new Map(newest.points.map((point) => [point.id, point]));
        const start = performance.now();
        signalChanges = new Map();
        if (observedKey && !motion.matches) {
          for (const [id, point] of points) {
            const prior = previous.get(id);
            if (!prior || prior.channel !== point.channel || Math.abs(prior.signal - point.signal) >= 3) {
              signalChanges.set(id, { prior, point, start });
            }
          }
          for (const [id, prior] of previous) {
            if (!points.has(id)) signalChanges.set(id, { prior, point: null, start });
          }
        }
        lastPoints = points;
        observedKey = newest.key;
      }
      const liveKeys = new Set(frames.map((item) => item.key));
      for (const key of profiles.keys()) {
        if (!liveKeys.has(key)) profiles.delete(key);
      }
      updateButtons();
    }

    function renderEpisodes() {
      const episodes = incidentList();
      const active = currentStory?.episode.id;
      const signature = episodes.map((item) => [item.id, item.count, item.id === active].join("/")).join("|");
      if (signature === lastEpisodeHtml) return;
      lastEpisodeHtml = signature;
      const holder = el("air-episodes");
      if (!episodes.length) {
        holder.textContent = "Пока нет";
        return;
      }
      holder.replaceChildren(...episodes.map((episode) => {
        const button = document.createElement("button");
        button.type = "button";
        button.className = "air-episode";
        const type = episode.route === "external" ? "Внешний отклик" :
          episode.route === "router" ? "Отклик роутера" : "Причина не установлена";
        button.setAttribute("aria-label", "Повторить эпизод " + clock(episode.at, true) + " · " + type);
        button.setAttribute("aria-pressed", String(episode.id === active));
        button.title = episode.message || type;
        button.append(svgIcon(episode.route === "external" ? "globe" : "loss"),
          document.createTextNode(clock(episode.at, true) + (episode.count > 1 ? " ×" + episode.count : "")));
        button.addEventListener("click", () => begin(episode));
        return button;
      }));
    }

    function candidate(band, confirmedOnly) {
      const next = state?.bands.find((entry) => entry.key === band)?.preview;
      return next && (!confirmedOnly || next.confirmed) ? next : null;
    }

    function frame() {
      if (!currentStory && comparisonSide) return compare[comparisonSide];
      if (!currentStory || currentStory.episode.route === "external" || storyStage === "locate") return null;
      const match = snapshotFor(currentStory.episode.at);
      return match && Math.abs(match.at - currentStory.episode.at) <= ageLimit ? match : null;
    }

    function updateButtons() {
      el("air-auto").setAttribute("aria-pressed", String(auto));
      el("air-preview").setAttribute("aria-pressed", String(preview || storyStage === "suggest"));
      el("air-overlap").setAttribute("aria-pressed", String(Boolean(xray)));
      el("air-preview").hidden = !state?.bands.some((band) => band.preview);
      el("air-preview").disabled = Boolean(currentStory);
      el("air-overlap").disabled = !(liveFrame() || snapshots.length);
      for (const key of ["A", "B"]) {
        const button = el("air-set-" + key.toLowerCase());
        button.disabled = !(liveFrame() || snapshots.length);
        button.setAttribute("aria-pressed", String(Boolean(compare[key])));
      }
      el("air-clear-compare").hidden = !compare.A && !compare.B;
      const swap = el("air-swap");
      swap.hidden = !compare.A || !compare.B;
      swap.textContent = comparisonSide === "A" ? "Показать B" : "Показать A";
    }

    function writeStory(stage, episode, match) {
      el("episode-story").hidden = !stage;
      const known = match && Math.abs(episode.at - match.at) <= ageLimit;
      const external = episode?.route === "external";
      const route = external ? "external" : episode?.route === "router" ? "router" : "";
      for (const item of document.querySelectorAll("[data-air-route]")) {
        item.classList.toggle("is-active", item.dataset.airRoute === route ||
          Boolean(known && route === "router" && stage !== "locate" && item.dataset.airRoute === "radio"));
      }
      document.querySelector(".diagnostics").classList.toggle("is-air-linked", Boolean(stage && episode));
      el("air-event-title").textContent = stage === "locate" ? "Скачок отклика · " + clock(episode.at, true) :
        stage === "suggest" ? "Примерка канала по подтверждённому совету" :
        stage === "inspect" && known ? "Срез эфира рядом со сбоем" :
        stage ? "Разбор эпизода · " + clock(episode.at, true) : "Эфир в реальном времени";
      let detail = episode?.message || "Карта связывает замеры сигнала со скачками задержки.";
      if (!external && stage && stage !== "locate") {
        if (known) {
          const offset = Math.round((match.at - episode.at) / 1000);
          const relative = offset === 0 ? "в момент скачка" : Math.abs(offset) + " с " + (offset < 0 ? "до" : "после") + " скачка";
          detail = "Снимок " + relative + ". " + detail;
        } else if (episode.route === "router") {
          detail = "Рядом со скачком нет свежего снимка эфира. " + detail;
        }
      }
      el("air-event-detail").textContent = detail;
    }

    function tick(now) {
      if (!currentStory) return false;
      const episode = currentStory.episode;
      const age = now - currentStory.start;
      const match = snapshotFor(episode.at);
      const confirmed = currentStory.passive && episode.route === "router" &&
        state?.now - episode.at < 30000 && match && Math.abs(match.at - episode.at) <= ageLimit &&
        candidate(episode.band, true);
      const stop = motion.matches ? 4800 : confirmed ? 9100 : 7000;
      const stage = age >= stop ? "" : age < (motion.matches ? 0 : 1450) ? "locate" :
        age > 5100 && confirmed ? "suggest" : "inspect";
      const lookupKey = stage === "locate" ? null : match?.key || null;
      if (!stage || stage !== storyStage || lookupKey !== storyMatchKey) {
        storyStage = stage;
        storyMatchKey = lookupKey;
        writeStory(stage, stage ? episode : null, stage ? match : null);
        if (!stage) currentStory = null;
        updateButtons();
        renderEpisodes();
        changed();
      }
      return Boolean(currentStory);
    }

    function showControls(selected, points) {
      const view = selected || liveFrame() || snapshots.at(-1);
      for (const key of ["A", "B"]) {
        const button = el("air-set-" + key.toLowerCase());
        button.dataset.frame = view?.key || "";
        button.textContent = compare[key] ? key + " · " + clock(compare[key].at, true) : "Снимок " + key;
      }
      const note = el("air-comparison");
      let content = "";
      if (compare.A && compare.B) {
        content = "A " + clock(compare.A.at, true) + " → B " + clock(compare.B.at, true) +
          " · зелёным отмечено ослабление пересечений, янтарным — усиление.";
      } else if (compare.A || compare.B) {
        content = "Выбери второй момент на шкале и закрепи его для сравнения.";
      } else if ((preview && !selected) || storyStage === "suggest") {
        const items = state.bands.filter((band) => band.preview && (preview || band.key === currentStory?.episode.band));
        content = items.map((band) => band.key.replace(".", ",") + " ГГц · " + band.preview.channel + " / " +
          band.preview.width + " МГц · оценка помех " + band.preview.fromScore + " → " + band.preview.toScore).join(" · ");
        if (content) content = "Расчётная примерка · " + content;
      } else if (xray) {
        const neighbors = [];
        for (const band of bands) {
          if (xray.band && xray.band !== band.key) continue;
          const visible = points.filter((point) => point.band === band.key);
          const own = privatePoint(visible);
          if (!own) continue;
          for (const point of visible) {
            if (!point.own && !point.stale && overlaps(own, point) &&
                (!xray.mhz || point.segments.some((segment) => inSegment(segment, xray.mhz)))) {
              neighbors.push(point.name + " " + point.signalText);
            }
          }
        }
        content = neighbors.length ? "Пересечение своей полосы · " + neighbors.slice(0, 5).join(" · ") +
          (neighbors.length > 5 ? " · ещё " + (neighbors.length - 5) : "") : "В выбранной области пересечение не обнаружено.";
      }
      note.textContent = content;
      note.hidden = !content;
      updateButtons();
    }

    function historyProfile(layer, band) {
      if (!profiles.has(layer.key)) profiles.set(layer.key, {});
      const cache = profiles.get(layer.key);
      if (!cache[band.key]) cache[band.key] = estimateProfile(layer.points, band);
      return cache[band.key];
    }

    function drawVolumes(now, selected, focus) {
      const episode = currentStory?.episode;
      const snapshot = episode && snapshotFor(episode.at);
      const recent = snapshot && Math.abs(snapshot.at - episode.at) <= ageLimit;
      for (const band of bands) {
        const canvas = el("air-volume-" + band.suffix);
        const isActive = episode?.route === "router" && episode.band === band.key;
        canvas.parentElement.classList.toggle("is-active", isActive);
        const ease = isActive ? Math.min(1, (now - currentStory.start) / 440) : 0;
        const { context, width, height } = sizeCanvas(canvas);
        drawVolume(context, width, height, band, snapshots, liveFrame(), selected, focus,
          isActive && recent ? { ...episode, snapshot } : null, motion.matches ? 0 : ease, historyProfile);
      }
    }

    function describeBand(band, selected) {
      return {
        preview: (!selected && preview) || (storyStage === "suggest" && currentStory?.episode.band === band.key) ?
          candidate(band.key, storyStage === "suggest") : null,
        compare: compare.A && compare.B ? compare : null,
        xray: xray && (!xray.band || xray.band === band.key) ? xray : null,
        pulse: currentStory?.episode.route === "router" && currentStory.episode.band === band.key,
      };
    }

    function drawBandOverlay(options) {
      const { context, band, width, floor, space, visible, own, position, arc, selected, now } = options;
      const view = describeBand(band, selected);
      if (view.compare) {
        const a = view.compare.A.points.filter((point) => point.band === band.key);
        const b = view.compare.B.points.filter((point) => point.band === band.key);
        const aOwn = privatePoint(a);
        const bOwn = privatePoint(b);
        if (!aOwn || !bOwn) return;
        for (const [point, tint] of [[aOwn, color.gold], [bOwn, color.cyan]]) {
          for (const segment of point.segments) {
            context.save();
            context.setLineDash([5, 4]);
            context.strokeStyle = tint;
            context.lineWidth = 1.5;
            context.stroke(arc(position(segment.Left), position(segment.Right), floor, space * point.signal / 100));
            context.restore();
          }
        }
        compareCoverage(a, b, aOwn, bOwn);
      } else if (view.preview && own) {
        const next = view.preview;
        for (const segment of next.segments) {
          const path = arc(position(segment.Left), position(segment.Right), floor, space * own.signal / 100 * .92);
          context.save();
          context.setLineDash([6, 4]);
          context.strokeStyle = "#ffe0a1";
          context.fillStyle = "#f1bd631b";
          context.fill(path);
          context.lineWidth = 1.65;
          context.stroke(path);
          context.restore();
        }
        compareCoverage(visible, visible, own, next);
      }
      if (view.pulse && own) {
        const age = now - currentStory.start;
        const strength = motion.matches ? .8 : Math.max(.34, 1 - (age % 1700) / 1700);
        markLoss(context, position(own.frequency), floor - Math.max(13, space * own.signal / 100) + 3,
          9 + (motion.matches ? 0 : 10 * (1 - strength)), strength);
      }

      function compareCoverage(before, after, ownA, ownB) {
        for (let i = 0; i < 110; i++) {
          const mhz = band.min + (band.max - band.min) * i / 110;
          const delta = coverage(after, ownB, mhz) - coverage(before, ownA, mhz);
          if (Math.abs(delta) < .06) continue;
          context.fillStyle = delta < 0 ? "#8ed1a0bc" : "#ff9c54c7";
          context.fillRect(position(mhz), floor - 5, Math.max(1, (width - 28) / 110), 4);
        }
      }
    }

    function renderedPoints(points, selected, now) {
      if (selected || motion.matches) return points;
      const updated = points.map((point) => {
        const change = signalChanges.get(point.id);
        if (!change || now - change.start > 1500) return point;
        const progress = Math.min(1, Math.max(0, (now - change.start) / 720));
        const eased = 1 - (1 - progress) ** 3;
        const prior = change.prior;
        const sameChannel = prior?.channel === point.channel;
        return { ...point,
          signal: sameChannel ? prior.signal + (point.signal - prior.signal) * eased : point.signal,
          fade: prior ? 1 : .15 + eased * .85,
          priorSignal: sameChannel ? prior.signal : null,
          deltaDb: sameChannel && prior.rssi != null && point.rssi != null ? point.rssi - prior.rssi : null,
          oldChannel: prior && !sameChannel ? prior.channel : null,
          oldFrequency: prior && !sameChannel ? prior.frequency : null,
          shift: prior && !sameChannel ? (prior.frequency - point.frequency) * (1 - eased) : 0,
          effectAlpha: Math.max(0, 1 - (now - change.start) / 1500),
        };
      });
      for (const change of signalChanges.values()) {
        if (!change.point && now - change.start < 1250 && !points.some((point) => point.id === change.prior.id)) {
          updated.push({ ...change.prior, stale: true, fade: Math.max(0, 1 - (now - change.start) / 1250) });
        }
      }
      return updated;
    }

    function activateXray(band, mhz) {
      cancel(true);
      compare = { A: null, B: null };
      xray = { band, mhz };
      preview = false;
      changed();
    }

    function cancel(userLocked = false) {
      locked = userLocked;
      currentStory = null;
      storyStage = "";
      preview = false;
      xray = null;
      comparisonSide = null;
      writeStory("", null, null);
      renderEpisodes();
      updateButtons();
    }

    function mount(getSelected) {
      el("air-episodes").textContent = "Пока нет";
      el("air-auto").addEventListener("click", () => {
        auto = !auto;
        try { localStorage.setItem("wifi-air-auto", auto ? "on" : "off"); } catch { }
        if (!auto && currentStory?.passive) cancel(locked);
        updateButtons();
        changed();
      });
      el("air-preview").addEventListener("click", () => {
        resetView();
        preview = !preview;
        locked = preview;
        xray = null;
        compare = { A: null, B: null };
        changed();
      });
      el("air-overlap").addEventListener("click", () => {
        const on = !xray;
        cancel(on);
        xray = on ? {} : null;
        preview = false;
        compare = { A: null, B: null };
        changed();
      });
      for (const key of ["A", "B"]) {
        el("air-set-" + key.toLowerCase()).addEventListener("click", () => {
          const selected = getSelected() || liveFrame() || snapshots.at(-1);
          if (!selected) return;
          cancel(true);
          compare[key] = selected;
          changed();
        });
      }
      el("air-swap").addEventListener("click", () => {
        if (!compare.A || !compare.B) return;
        resetView();
        comparisonSide = comparisonSide === "A" ? "B" : "A";
        changed();
      });
      el("air-clear-compare").addEventListener("click", () => {
        compare = { A: null, B: null };
        comparisonSide = null;
        locked = false;
        changed();
      });
      for (const band of bands) {
        const canvas = el("air-volume-" + band.suffix);
        const selectAt = (event) => {
          if (!snapshots.length) return;
          const depth = Math.max(0, Math.min(1, (canvas.clientHeight - 26 - event.offsetY) / (canvas.clientHeight * .52)));
          const newest = snapshots.at(-1).at;
          const span = Math.max(30000, newest - snapshots[0].at);
          const when = newest - span * depth;
          const closest = snapshots.reduce((best, item) =>
            Math.abs(item.at - when) < Math.abs(best.at - when) ? item : best);
          chooseSlice(closest.key);
        };
        canvas.addEventListener("pointerdown", (event) => {
          if (!snapshots.length || event.button !== 0) return;
          canvas.setPointerCapture(event.pointerId);
          selectAt(event);
        });
        canvas.addEventListener("pointermove", (event) => {
          if (canvas.hasPointerCapture(event.pointerId)) selectAt(event);
        });
      }
      updateButtons();
    }

    return {
      readState, readArchive, frame, mount, showControls, tick, drawVolumes, drawBandOverlay,
      describeBand, renderedPoints, activateXray, cancel,
      eventTime() { return currentStory?.episode.at ?? null; },
      replayNearest(at) {
        const match = incidentList().sort((a, b) => Math.abs(a.at - at) - Math.abs(b.at - at))[0];
        if (match && Math.abs(match.at - at) <= 9000) begin(match);
      },
      animating(now) {
        return !motion.matches && [...signalChanges.values()].some((entry) => now - entry.start < 1500);
      },
    };
  }

  return { create, markRouter, hexagon, overlaps, inSegment };
})();
