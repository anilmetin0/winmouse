const root = document.documentElement;
const tr = root.lang === "tr";
const repo = "anilmetin0/winmouse";
const reduce = matchMedia("(prefers-reduced-motion: reduce)");

// Scroll reveals. The inline script in <head> adds .rv; this marks that the observer took over.
if (root.classList.contains("rv")) {
  root.dataset.revealReady = "1";
  const io = new IntersectionObserver((entries) => {
    for (const e of entries) {
      if (!e.isIntersecting) continue;
      e.target.classList.add("in");
      io.unobserve(e.target);
    }
  }, { rootMargin: "0px 0px -8% 0px", threshold: 0.12 });
  document.querySelectorAll("[data-reveal]").forEach((el, i, all) => {
    const prev = all[i - 1];
    el.style.setProperty("--i", prev && prev.parentElement === el.parentElement ? 1 : 0);
    io.observe(el);
  });
}

// Theme switch; the choice is remembered, otherwise the system setting applies.
document.querySelector(".theme")?.addEventListener("click", () => {
  const next = root.dataset.theme === "dark" ? "light" : "dark";
  root.dataset.theme = next;
  try { localStorage.setItem("theme", next); } catch {}
});

// Rulers: a long tick every 100 points, the distance of one wheel notch.
function drawRulers() {
  for (const r of document.querySelectorAll(".ruler")) {
    const n = Math.ceil(r.clientWidth / 100);
    if (r.childElementCount === n) continue;
    r.replaceChildren(...Array.from({ length: n }, (_, i) => {
      const s = document.createElement("span");
      s.style.left = i * 100 + "px";
      s.textContent = i === 0 ? "0 pt" : i * 100;
      return s;
    }));
  }
}
drawRulers();
addEventListener("resize", drawRulers);

// Copy the build commands
for (const btn of document.querySelectorAll("[data-copy]")) {
  const label = btn.querySelector(".lbl");
  btn.addEventListener("click", async () => {
    const text = document.getElementById(btn.dataset.copy).textContent.trim();
    try {
      await navigator.clipboard.writeText(text);
      btn.classList.add("done");
      label.textContent = tr ? "Kopyalandı" : "Copied";
    } catch {
      label.textContent = tr ? "Kopyalanamadı, metni seçip kopyalayın" : "Copy failed, select the text";
    }
    clearTimeout(btn.t);
    btn.t = setTimeout(() => {
      btn.classList.remove("done");
      label.textContent = btn.dataset.label;
    }, 2200);
  });
}

// Version and download of the newest release, prereleases included (/releases/latest skips
// them). The links work without this.
fetch(`https://api.github.com/repos/${repo}/releases?per_page=10`)
  .then((r) => (r.ok ? r.json() : Promise.reject()))
  .then((list) => {
    const release = list.find((r) => !r.draft);
    if (!release) return;
    const dmg = release.assets.find((a) => /^WinMouse-.+\.dmg$/.test(a.name));
    for (const a of document.querySelectorAll('[data-asset="dmg"]')) a.href = dmg ? dmg.browser_download_url : release.html_url;
    const version = release.tag_name.replace(/^v/, "");
    for (const el of document.querySelectorAll("[data-version]")) el.textContent = version;
  })
  .catch(() => {});

// Star count next to the GitHub link
fetch(`https://api.github.com/repos/${repo}`)
  .then((r) => (r.ok ? r.json() : Promise.reject()))
  .then((info) => {
    const box = document.querySelector(".stars");
    if (!box || !(info.stargazers_count > 0)) return;
    box.querySelector("[data-stars]").textContent = info.stargazers_count.toLocaleString(root.lang);
    box.hidden = false;
  })
  .catch(() => {});

/* ---------- Windows pointer model (docs/research/windows-pointer.md) ----------
   Default Windows 10 SmoothMouseXCurve / SmoothMouseYCurve, 100 % display scale.
   EPP on:  pixels = 0.8 * (speed / 10) * Y(counts / 3.5)
   EPP off: pixels = counts * factor(speed)                                        */
const CX = [0, 0.430008, 1.25, 3.860001, 40];
const CY = [0, 1.070267, 4.140625, 18.984375, 443.75];
function curveY(x) {
  for (let i = 1; i < CX.length; i++) {
    if (x <= CX[i] || i === CX.length - 1) return CY[i - 1] + (CY[i] - CY[i - 1]) * (x - CX[i - 1]) / (CX[i] - CX[i - 1]);
  }
}
const offFactor = (s) => (s <= 2 ? s / 32 : s <= 10 ? (s - 2) / 8 : (s - 6) / 4);
const pixels = (m, s, epp) => (epp ? 0.8 * (s / 10) * curveY(m / 3.5) : m * offFactor(s));
const gain = (m, s, epp) => (m < 1e-9 ? pixels(1e-6, s, epp) / 1e-6 : pixels(m, s, epp) / m);

const speed = document.getElementById("speed");
const epp = document.getElementById("epp");
const live = document.querySelector(".chart .live");
const liveArea = document.querySelector(".chart .live-area");
const readout = document.getElementById("readout");
const out = document.getElementById("speed-out");
if (speed && epp && live) {
  const ms = [0, 1.505];
  for (let m = 2; m <= 64; m += 0.5) ms.push(m);
  const fmt = (n) => n.toLocaleString(root.lang, { maximumFractionDigits: n < 10 ? 1 : 0 });
  const update = () => {
    const s = +speed.value, on = epp.checked;
    out.textContent = s;
    const pts = ms.map((m) => `${(56 + m / 64 * 564).toFixed(1)} ${(360 - Math.min(gain(m, s, on), 5.3) / 5 * 340).toFixed(1)}`);
    live.setAttribute("d", "M" + pts.join("L"));
    liveArea.setAttribute("d", "M56 360L" + pts.join("L") + "L620 360Z");
    const a = fmt(pixels(8, s, on)), b = fmt(pixels(32, s, on));
    const px = (v) => (tr ? `${v} piksel` : `${v} ${v === "1" ? "pixel" : "pixels"}`);
    readout.innerHTML = tr
      ? `Hız ${s}, hassasiyet ${on ? "açık" : "kapalı"}: 8 sayımlık bir rapor imleci <b>${px(a)}</b>, 32 sayımlık bir rapor <b>${px(b)}</b> taşır.`
      : `Speed ${s}, precision ${on ? "on" : "off"}: a report of 8 counts moves the pointer <b>${px(a)}</b>, a report of 32 counts <b>${px(b)}</b>.`;
  };
  speed.addEventListener("input", update);
  epp.addEventListener("change", update);
  update();
}

/* ---------- wheel: one notch = 3 lines = 100 points, 200 ms, cubic-bezier(0.42, 0, 0.58, 1)
   (docs/research/windows-scroll.md) ---------- */
const track = document.querySelector(".track");
if (track) {
  const LINES = 90, LINE = 100 / 3, H = LINES * LINE;
  const doc = track.querySelector(".doc");
  const scale = track.querySelector(".scale");
  const rows = [];
  for (let i = 1; i <= LINES; i++) {
    const p = document.createElement("p");
    const b = document.createElement("b");
    b.textContent = i;
    const bar = document.createElement("i");
    bar.style.width = 38 + ((i * 37) % 55) + "%";
    p.append(b, bar);
    rows.push(p);
  }
  doc.append(...rows);
  scale.style.height = H + "px";
  for (let y = 0; y < H; y += LINE) {
    const mk = document.createElement("span");
    const notch = Math.round(y) % 100 === 0;
    mk.className = notch ? "mk" : "mk minor";
    mk.style.top = y + "px";
    if (notch) mk.textContent = Math.round(y);
    scale.append(mk);
  }
  const view = track.querySelector(".view");
  const offset = () => view.offsetTop;
  const max = H - track.clientHeight + offset();
  let pos = -offset(), target = pos, anim = null, dotAnim = 0;
  const setY = (y) => { pos = y; const t = `translateY(${-y}px)`; doc.style.transform = t; scale.style.transform = t; };
  setY(pos);

  // cubic-bezier(0.42, 0, 0.58, 1): solve x(t) = u, return y(t)
  const bez = (u) => {
    let lo = 0, hi = 1, t = u;
    for (let i = 0; i < 24; i++) {
      t = (lo + hi) / 2;
      const x = 3 * (1 - t) ** 2 * t * 0.42 + 3 * (1 - t) * t * t * 0.58 + t ** 3;
      if (x < u) lo = t; else hi = t;
    }
    return 3 * (1 - t) * t * t + t ** 3;
  };
  const dot = document.getElementById("ease-dot");
  const note = document.getElementById("notch-out");

  for (const btn of document.querySelectorAll("[data-notch]")) {
    btn.addEventListener("click", () => {
      target = Math.max(-offset(), Math.min(max, target + 100 * +btn.dataset.notch));
      const from = pos, to = target;
      const lines = Math.round((to + offset()) / LINE);
      note.textContent = tr ? `Sayfa ${lines} satır, ${Math.round(to + offset())} punto kaydı.` : `Scrolled ${lines} lines, ${Math.round(to + offset())} points.`;
      cancelAnimationFrame(anim);
      cancelAnimationFrame(dotAnim);
      if (reduce.matches) { setY(to); return; }
      const start = performance.now();
      const step = (now) => {
        const u = Math.min(1, (now - start) / 200);
        const e = bez(u);
        setY(from + (to - from) * e);
        if (dot) { dot.setAttribute("cx", 50 + 450 * u); dot.setAttribute("cy", 250 - 220 * e); }
        if (u < 1) anim = requestAnimationFrame(step);
      };
      anim = requestAnimationFrame(step);
    });
  }
}
