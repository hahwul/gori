/* The landing's field: one fixed canvas, eight scenes, ordered dither.
   Every scene paints greys onto a small offscreen layer (one cell = CELL css
   px). Each frame crossfades the two chapters nearest the scroll position and
   quantises the mix to the four inks the stylesheet sets as --art-0..3 on
   .home-main, through an 8x8 Bayer matrix. Crossfading luminance under an
   ordered dither is what makes a screen dissolve into dots and re-form as
   the next one. The chapters snap (CSS scroll-snap), so the scroll position
   jumps; `p` eases toward it and the dissolve takes the eased path. The DOM
   carries the words: no script, or reduced motion, leaves eight readable
   screens, and reduced motion also drops the ambient drift and the glyph
   decode. */
(function () {
  var cv = document.getElementById("homeArt");
  var main = document.querySelector(".home-main");
  if (!cv || !main) return;
  var g = cv.getContext("2d");
  var reduced = matchMedia("(prefers-reduced-motion: reduce)").matches;
  var CELL = 3;

  var PAL = [[8, 10, 17], [58, 61, 88], [200, 168, 96], [246, 245, 241]];
  function readPalette() {
    var cs = getComputedStyle(main), next = [];
    for (var i = 0; i < 4; i++) {
      var m = /^#?([0-9a-f]{6})$/i.exec(cs.getPropertyValue("--art-" + i).trim());
      if (!m) return;
      next.push([parseInt(m[1].slice(0, 2), 16), parseInt(m[1].slice(2, 4), 16), parseInt(m[1].slice(4, 6), 16)]);
    }
    PAL = next;
  }
  readPalette();
  new MutationObserver(readPalette).observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme"] });

  var BAYER = (function () {
    var m = [[0, 32, 8, 40, 2, 34, 10, 42], [48, 16, 56, 24, 50, 18, 58, 26], [12, 44, 4, 36, 14, 46, 6, 38], [60, 28, 52, 20, 62, 30, 54, 22], [3, 35, 11, 43, 1, 33, 9, 41], [51, 19, 59, 27, 49, 17, 57, 25], [15, 47, 7, 39, 13, 45, 5, 37], [63, 31, 55, 23, 61, 29, 53, 21]];
    var f = new Float32Array(64);
    for (var y = 0; y < 8; y++) for (var x = 0; x < 8; x++) f[y * 8 + x] = (m[y][x] + 0.5) / 64 - 0.5;
    return f;
  })();

  var off = document.createElement("canvas");
  var mix = off.getContext("2d", { willReadFrequently: true });
  /* Two scene layers so a veil one scene draws cannot bleed into the other. */
  var layers = [document.createElement("canvas"), document.createElement("canvas")];
  var lctx = layers.map(function (c) { return c.getContext("2d"); });
  var o = lctx[0];
  var W = 0, H = 0, out = null, stars = null;

  function resize() {
    CELL = 3;
    /* Cap the per-frame work on very wide screens by coarsening the cell. */
    while ((innerWidth / CELL) * (innerHeight / CELL) > 520000) CELL++;
    W = Math.ceil(innerWidth / CELL); H = Math.ceil(innerHeight / CELL);
    cv.width = off.width = layers[0].width = layers[1].width = W;
    cv.height = off.height = layers[0].height = layers[1].height = H;
    out = g.createImageData(W, H);
    stars = null;
  }

  function load(src) { var i = new Image(); i.src = src; return i; }
  var knot = load(cv.getAttribute("data-knot"));
  var wall = load(cv.getAttribute("data-wall"));
  var shots = cv.getAttribute("data-shots").split(",").map(load);
  function ok(i) { return i.complete && i.naturalWidth > 0; }

  function rnd(s) { return function () { s = (s * 1664525 + 1013904223) >>> 0; return s / 4294967296; }; }
  function grey(l) {
    var v = Math.round(Math.max(0, Math.min(1, l)) * 255);
    o.fillStyle = o.strokeStyle = "rgb(" + v + "," + v + "," + v + ")";
  }
  function ease(t) { return t < 0.5 ? 2 * t * t : 1 - Math.pow(-2 * t + 2, 2) / 2; }
  function drawStars(time, lum) {
    if (!stars) {
      var r = rnd(7), n = Math.floor(W * H / 900); stars = [];
      for (var i = 0; i < n; i++) stars.push([r() * W, r() * H, r() * 6.28, 0.3 + r() * 0.5]);
    }
    for (var k = 0; k < stars.length; k++) {
      var s = stars[k], tw = reduced ? 1 : 0.6 + 0.4 * Math.sin(time * 1.3 + s[2]);
      grey(s[3] * tw * lum); o.fillRect(s[0] | 0, s[1] | 0, 1, 1);
    }
  }
  function ring(cx, cy, rx, ry, w, l, a0, a1) {
    grey(l); o.lineWidth = w; o.beginPath();
    o.ellipse(cx, cy, rx, ry, 0, a0 || 0, a1 == null ? 6.2832 : a1); o.stroke();
  }
  /* A dark pool in the field behind the words, so the type reads over art. */
  function pool(cx, cy, r, a) {
    var gr = o.createRadialGradient(cx, cy, 0, cx, cy, r);
    gr.addColorStop(0, "rgba(0,0,0," + a + ")"); gr.addColorStop(1, "rgba(0,0,0,0)");
    o.fillStyle = gr; o.fillRect(0, 0, W, H);
  }
  function drawKnot(cx, cy, size, rot, bright) {
    if (!ok(knot)) { ring(cx, cy, size * 0.42, size * 0.3, size * 0.08, 0.62); return; }
    o.save(); o.translate(cx, cy); o.rotate(rot || 0);
    o.filter = "grayscale(1) brightness(" + (bright || 1.15) + ")";
    o.drawImage(knot, -size / 2, -size / 2, size, size);
    o.restore(); o.filter = "none";
  }

  /* Each scene: t is arrival (1 when the chapter is centred), time seconds. */
  var scenes = [
    function title(t, time) {
      drawStars(time, 0.5);
      var s = Math.min(W, H) * (0.14 + 0.22 * ease(t));
      drawKnot(W / 2 + Math.sin(time * 0.3) * 2, H * 0.4, s, reduced ? 0 : time * 0.08);
    },
    function thesis(t, time) {
      drawStars(time, 0.35);
      var s = Math.min(W * 0.8, H * 1.0) * (0.6 + 0.4 * ease(t));
      drawKnot(W / 2, H / 2, s, reduced ? 0 : -0.2 + time * 0.05, 0.72);
      pool(W / 2, H / 2, W * 0.34, 0.82);
    },
    function loop(t, time) {
      drawStars(time, 0.3);
      var e = ease(t), cx = W / 2, cy = H / 2, rx = W * 0.38 * (0.7 + 0.3 * e), ry = H * 0.3 * (0.7 + 0.3 * e);
      ring(cx, cy, rx, ry, Math.max(2, H * 0.012), 0.34);
      ring(cx, cy, rx * 0.985, ry * 0.985, 1, 0.18);
      for (var i = 0; i < 6; i++) {
        var dir = i % 2 ? 1 : -1, a = (time * 0.7 * dir + i * 1.05) % 6.2832;
        ring(cx, cy, rx, ry, Math.max(3, H * 0.018), 0.95, a, a + 0.22);
      }
      grey(0.55);
      o.beginPath(); o.ellipse(cx - rx, cy, H * 0.03, H * 0.03, 0, 0, 6.3); o.fill();
      o.beginPath(); o.ellipse(cx + rx, cy, H * 0.03, H * 0.03, 0, 0, 6.3); o.fill();
      drawKnot(cx, cy - ry, H * 0.14, 0, 1.1);
      pool(cx, cy, W * 0.3, 0.7);
    },
    function numbers(t, time) {
      /* A History table raining past: rows of short bars. */
      var rowH = Math.max(4, H * 0.028), n = Math.ceil(H / rowH) + 2;
      var scroll = reduced ? 0 : (time * rowH * 1.4) % rowH;
      for (var i = -1; i < n; i++) {
        var y = i * rowH - scroll, seed = (i + Math.floor(reduced ? 0 : time * 1.4)) | 0;
        var rr = rnd(seed * 31 + 7), x = W * 0.06, cols = 6 + Math.floor(rr() * 3);
        for (var c = 0; c < cols; c++) {
          var w = W * (0.03 + rr() * 0.11);
          grey(c === 2 && rr() > 0.6 ? 0.5 : 0.1 + rr() * 0.12);
          o.fillRect(x, y, w, Math.max(1, rowH * 0.35));
          x += w + W * 0.02;
          if (x > W * 0.94) break;
        }
      }
      grey(0); o.globalAlpha = 1 - 0.6 * ease(t); o.fillRect(0, 0, W, H); o.globalAlpha = 1;
      pool(W / 2, H / 2, W * 0.5, 0.85);
    },
    function workbench(t, time) {
      drawStars(time, 0.25);
      var narrow = W * CELL < 900;
      var sw = narrow ? W * 0.86 : W * 0.36, sx = narrow ? W * 0.07 : W * 0.1;
      var fh = sw * 0.46, gap = fh * 0.22, period = fh + gap;
      var y0 = reduced ? 0 : -((time * period * 0.22) % period);
      grey(narrow ? 0.12 : 0.2); o.fillRect(sx, 0, sw, H);
      for (var y = y0 - period; y < H + period; y += period) {
        var idx = ((Math.round((y - y0) / period) % shots.length) + shots.length) % shots.length, im = shots[idx];
        grey(0.05); o.fillRect(sx + sw * 0.08, y, sw * 0.84, fh);
        if (ok(im)) {
          o.filter = "grayscale(1) contrast(1.3) brightness(" + (narrow ? 0.7 : 1.1) + ")";
          o.drawImage(im, sx + sw * 0.08, y, sw * 0.84, fh); o.filter = "none";
        }
        for (var k = 0; k < 4; k++) {
          grey(0); var hy = y + k * (fh / 4) + fh * 0.06;
          o.fillRect(sx + sw * 0.02, hy, sw * 0.035, fh * 0.1);
          o.fillRect(sx + sw * 0.945, hy, sw * 0.035, fh * 0.1);
        }
      }
      grey(0); o.globalAlpha = 1 - ease(t); o.fillRect(0, 0, W, H); o.globalAlpha = 1;
      if (narrow) pool(W / 2, H / 2, W * 0.6, 0.85);
    },
    function seam(t, time) {
      drawStars(time, 0.25);
      var cy = H * 0.68, lx = W * 0.22, rx = W * 0.78, r = H * 0.045;
      grey(0.3); o.fillRect(lx, cy - 1, rx - lx, 2);
      for (var i = 0; i < 4; i++) {
        var ph = ((reduced ? 0.5 : time * 0.35) + i * 0.25) % 1;
        ring(rx, cy, r + ph * W * 0.22, r + ph * W * 0.22, 1, 0.5 * (1 - ph) * ease(t));
      }
      grey(0.6); o.beginPath(); o.ellipse(lx, cy, r, r, 0, 0, 6.3); o.fill();
      drawKnot(rx, cy, r * 3.2, 0, 1.1);
      for (var k = 0; k < 5; k++) {
        var dir = k % 2 ? -1 : 1, u = ((reduced ? 0.3 : time * 0.45) * dir + k * 0.2) % 1;
        if (u < 0) u += 1;
        grey(0.95); o.fillRect(lx + (rx - lx) * u, cy - 2, Math.max(3, W * 0.012), 4);
      }
    },
    function name(t, time) {
      drawStars(time, 0.3);
      var e = ease(t), cy = H * 0.36, r = H * 0.3, dx = r * (1.6 - 0.9 * e);
      ring(W / 2 - dx, cy, r, r, 1, 0.3);
      ring(W / 2 + dx, cy, r, r, 1, 0.3);
      ring(W / 2, cy, r, r, 1, 0.42);
      /* The word is set at the field's resolution, so it comes out as pixel Hangul. */
      o.font = "bold " + Math.round(H * 0.42) + "px 'Apple SD Gothic Neo','Noto Sans KR','Malgun Gothic',sans-serif";
      o.textAlign = "center"; o.textBaseline = "alphabetic";
      grey(0.66 * e); o.fillText("고리", W / 2, cy + H * 0.16);
    },
    function close(t, time) {
      var e = ease(t);
      if (ok(wall)) {
        var s = Math.max(W / wall.naturalWidth, H / wall.naturalHeight) * 1.06;
        var dw = wall.naturalWidth * s, dh = wall.naturalHeight * s;
        var dx = (W - dw) / 2 + (reduced ? 0 : Math.sin(time * 0.1) * W * 0.02), dy = (H - dh) / 2 + (1 - e) * H * 0.35;
        o.filter = "grayscale(1) contrast(1.25) brightness(" + (0.25 + 0.75 * e) + ")";
        o.drawImage(wall, dx, dy, dw, dh); o.filter = "none";
      } else drawStars(time, 0.4 * e);
      grey(0); o.globalAlpha = 0.35; o.fillRect(0, 0, W, H); o.globalAlpha = 1;
      pool(W / 2, H * 0.42, W * 0.28, 0.6);
    }
  ];

  var p = 0, target = 0, last = 0, t0 = performance.now();
  function scenePos() { return Math.max(0, Math.min(scenes.length - 1, scrollY / innerHeight)); }

  function paint(layer, idx, time) {
    o = lctx[layer]; o.globalAlpha = 1; o.filter = "none"; o.fillStyle = "#000"; o.fillRect(0, 0, W, H);
    scenes[idx](Math.max(0, 1 - Math.abs(p - idx)), time);
    o.globalAlpha = 1;
  }
  function render(time) {
    var a = Math.floor(p), f = p - a, b = Math.min(a + 1, scenes.length - 1);
    mix.globalAlpha = 1; mix.fillStyle = "#000"; mix.fillRect(0, 0, W, H);
    paint(0, a, time);
    mix.globalAlpha = 1 - f; mix.drawImage(layers[0], 0, 0);
    if (f > 0.001 && b !== a) { paint(1, b, time); mix.globalAlpha = f; mix.drawImage(layers[1], 0, 0); }
    mix.globalAlpha = 1;
    var src = mix.getImageData(0, 0, W, H).data, dst = out.data;
    for (var y = 0, i = 0; y < H; y++) {
      var by = (y & 7) << 3;
      for (var x = 0; x < W; x++, i += 4) {
        var L = (src[i] * 0.2126 + src[i + 1] * 0.7152 + src[i + 2] * 0.0722) / 255;
        var q = Math.round(L * 3 + BAYER[by | (x & 7)]);
        q = q < 0 ? 0 : q > 3 ? 3 : q;
        var c = PAL[q]; dst[i] = c[0]; dst[i + 1] = c[1]; dst[i + 2] = c[2]; dst[i + 3] = 255;
      }
    }
    g.putImageData(out, 0, 0);
  }

  var rail = document.querySelectorAll(".home-rail a"), hint = document.querySelector(".home-hint"), railOn = -1;
  function frame(now) {
    var dt = Math.min(0.1, (now - last) / 1000); last = now;
    target = scenePos();
    p = reduced ? target : p + (target - p) * (1 - Math.exp(-dt / 0.22));
    if (Math.abs(target - p) < 0.003) p = target;
    var idx = Math.round(p);
    if (idx !== railOn) {
      railOn = idx;
      for (var i = 0; i < rail.length; i++) rail[i].classList.toggle("is-on", i === idx);
    }
    if (hint) hint.classList.toggle("is-off", scrollY > innerHeight * 0.3);
    if (!document.hidden) render((now - t0) / 1000);
    requestAnimationFrame(frame);
  }

  resize(); addEventListener("resize", resize);
  requestAnimationFrame(frame);

  /* --- The words: letters settle left to right when a chapter arrives --- */
  var GLYPHS = "@#%&*+=:-.·░▒▓01<>/\\|";
  function decode(el, dur) {
    var txt = el.dataset.text || (el.dataset.text = el.textContent);
    if (reduced) { el.textContent = txt; return; }
    var start = performance.now(); dur = dur || 700;
    (function tick(now) {
      var u = Math.min(1, (now - start) / dur), n = Math.floor(u * txt.length), s = txt.slice(0, n);
      for (var i = n; i < txt.length; i++) s += txt[i] === " " ? " " : GLYPHS[(Math.random() * GLYPHS.length) | 0];
      el.textContent = s; if (u < 1) requestAnimationFrame(tick);
    })(start);
  }
  var io = new IntersectionObserver(function (es) {
    es.forEach(function (e) {
      if (!e.isIntersecting) return;
      e.target.querySelectorAll("[data-decode]").forEach(function (el, i) {
        setTimeout(function () { decode(el, 500 + i * 40); }, i * 70);
      });
    });
  }, { threshold: 0.55 });
  document.querySelectorAll(".home-ch").forEach(function (s) { io.observe(s); });

  var tools = ["list_history", "get_flow", "send_request", "fuzz_start", "probe_scan", "create_issue"], ti = 0;
  var toolEl = document.getElementById("homeTool");
  if (toolEl && !reduced) setInterval(function () { ti = (ti + 1) % tools.length; toolEl.dataset.text = tools[ti]; decode(toolEl, 420); }, 1600);

  var copy = document.getElementById("homeCopy"), cmd = document.getElementById("homeCmd");
  if (copy && cmd) copy.addEventListener("click", function () {
    var label = copy.textContent;
    function done() { copy.textContent = copy.getAttribute("data-copied"); setTimeout(function () { copy.textContent = label; }, 1400); }
    function select() { var r = document.createRange(); r.selectNodeContents(cmd); var s = getSelection(); s.removeAllRanges(); s.addRange(r); }
    if (navigator.clipboard && window.isSecureContext) navigator.clipboard.writeText(cmd.textContent).then(done, select);
    else select();
  });
})();
