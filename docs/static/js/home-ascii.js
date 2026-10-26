/* The landing hero's ring knot, drawn as a field of monospace glyphs on a
   canvas. The brand mark (images/gori.svg) is sampled once per resize into a
   per-cell coverage grid; each cell maps its coverage to a glyph on a density
   ramp, so the knot reads as ASCII art that still has the logo's exact shape.

   The glyphs themselves never move. What moves is light: a soft diagonal
   band of highlight, the way a glint runs across polished metal when it is
   tilted. Under the pointer the band glides after the cursor and the cells
   it crosses turn from gold to a warm white; when the pointer leaves, the
   band fades. Left alone, the knot catches one sweep of light every few
   seconds, the first soon after load, and is otherwise still.

   Gates: the canvas is aria-hidden decoration over an <img> fallback that
   html.js hides, so no-script visits see the plain mark. Reduced motion draws
   one still frame and skips every listener. Off-screen or in a hidden tab
   the loop stops (IntersectionObserver + requestAnimationFrame), and so does
   it whenever the light has settled, since a still frame needs no redraw.
   The theme swap is picked up from data-theme, so gold turns bronze on
   paper and the glint turns to ink. */
(function () {
  var box = document.getElementById("heroArt");
  var canvas = document.getElementById("heroAscii");
  if (!box || !canvas || !canvas.getContext) return;
  var ctx = canvas.getContext("2d");
  if (!ctx) return;

  var RAMP = " .:-=+*#%@";
  var LAST = RAMP.length - 1;
  var FONT = "ui-monospace, \"SF Mono\", \"Cascadia Code\", Menlo, Consolas, monospace";
  var STEPS = 12;                   /* gold → glint colour ramp resolution */
  var SWEEP_EVERY = 4800;           /* ms between idle glints */
  var SWEEP_TAKES = 2400;           /* ms one idle glint takes to cross */
  var SWEEP_FIRST = 900;            /* ms after load until the first one */
  var reduced = window.matchMedia("(prefers-reduced-motion: reduce)");

  var cw = 0, ch = 0, cols = 0, rows = 0, px = 13, dpr = 1, padX = 0, padY = 0, W = 0, H = 0;
  var cover = new Float32Array(0);   /* logo coverage per cell, 0..1 */
  var seed = new Float32Array(0);    /* per-cell hash, for the dust */
  var palette = [];                  /* STEPS+1 colours, gold → glint */
  var dust = "#8d90a2";
  var raf = 0, last = 0, visible = true, ready = false, sweepTimer = 0;

  /* The light: where the band is (px, box space), how strong, and where it
     is heading. `want` is the pointer; `lx/ly` ease toward it. */
  var lx = 0, ly = 0, wantX = 0, wantY = 0, strength = 0, wantStrength = 0;
  var hovering = false;
  var sweep = null;                  /* {t0} while an idle glint crosses */
  /* Scroll-driven state (home.js, through canvas.goriKnot): the light's
     place while the opening scene scrubs, and how far the knot has
     scattered into the terminal's arrival. */
  var scrollLight = null;            /* {x, y, s} in box px, or null */
  var scatter = 0;                   /* 0 whole .. 1 gone */
  var drift = new Float32Array(0);   /* per-cell scatter vector, x then y */

  var img = new Image();
  img.decoding = "async";
  img.src = canvas.getAttribute("data-src");

  function hex(c) {
    c = c.trim();
    if (c.charAt(0) === "#" && c.length === 4) {
      c = "#" + c.charAt(1) + c.charAt(1) + c.charAt(2) + c.charAt(2) + c.charAt(3) + c.charAt(3);
    }
    if (c.charAt(0) !== "#" || c.length !== 7) return null;
    return [parseInt(c.slice(1, 3), 16), parseInt(c.slice(3, 5), 16), parseInt(c.slice(5, 7), 16)];
  }

  function readTheme() {
    var cs = getComputedStyle(document.documentElement);
    var a = hex(cs.getPropertyValue("--accent")) || [200, 168, 96];
    var g = hex(cs.getPropertyValue("--hero-glint")) || [255, 243, 207];
    dust = cs.getPropertyValue("--muted").trim() || dust;
    palette = [];
    for (var i = 0; i <= STEPS; i++) {
      var t = i / STEPS;
      palette.push("rgb(" +
        Math.round(a[0] + (g[0] - a[0]) * t) + "," +
        Math.round(a[1] + (g[1] - a[1]) * t) + "," +
        Math.round(a[2] + (g[2] - a[2]) * t) + ")");
    }
  }

  /* Sample the mark into the cell grid. The logo is square; a cell is not,
     so it spans rows*ch/cw columns to keep its proportions. A 4x supersample
     averaged per cell gives smooth edge coverage, which is what makes the
     rim of the rings fall down the ramp instead of stepping off a cliff. */
  function sample() {
    var ss = 4;
    var off = document.createElement("canvas");
    off.width = cols * ss;
    off.height = rows * ss;
    var o = off.getContext("2d");
    var sideRows = rows * 0.94;
    var sideCols = sideRows * ch / cw;
    if (sideCols > cols * 0.98) {
      sideCols = cols * 0.98;
      sideRows = sideCols * cw / ch;
    }
    o.drawImage(
      img,
      (cols - sideCols) / 2 * ss, (rows - sideRows) / 2 * ss,
      sideCols * ss, sideRows * ss
    );
    var data = o.getImageData(0, 0, off.width, off.height).data;
    var n = cols * rows;
    cover = new Float32Array(n);
    seed = new Float32Array(n);
    drift = new Float32Array(2 * n);
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        var sum = 0;
        for (var y = 0; y < ss; y++) {
          var row = ((r * ss + y) * off.width + c * ss) * 4 + 3;
          for (var x = 0; x < ss; x++) sum += data[row + x * 4];
        }
        var i = r * cols + c;
        cover[i] = sum / (ss * ss * 255);
        /* Deterministic hash, so a resize does not reshuffle the dust. */
        var h = Math.sin(c * 12.9898 + r * 78.233) * 43758.5453;
        seed[i] = h - Math.floor(h);
        /* Scatter: away from the centre, each cell at its own pace. */
        var ang = Math.atan2(r - rows / 2, (c - cols / 2) * cw / ch) + (seed[i] - 0.5) * 1.2;
        var mag = 0.35 + seed[i] * 0.9;
        drift[2 * i] = Math.cos(ang) * mag;
        drift[2 * i + 1] = Math.sin(ang) * mag;
      }
    }
  }

  function resize() {
    var rect = box.getBoundingClientRect();
    if (rect.width < 1 || rect.height < 1) return;
    W = rect.width;
    H = rect.height;
    dpr = Math.min(window.devicePixelRatio || 1, 2);
    px = W < 360 ? 10 : W < 520 ? 12 : 13;
    ctx.font = px + "px " + FONT;
    /* The real advance of the font that was resolved, so the knot keeps its
       proportions whatever monospace the platform supplies. */
    cw = ctx.measureText("@").width || px * 0.6;
    ch = px * 1.04;
    cols = Math.floor(W / cw);
    rows = Math.floor(H / ch);
    /* Centre the grid: the box is rarely a whole number of cells. */
    padX = (W - cols * cw) / 2;
    padY = (H - rows * ch) / 2;
    canvas.width = Math.round(W * dpr);
    canvas.height = Math.round(H * dpr);
    canvas.style.width = W + "px";
    canvas.style.height = H + "px";
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    /* Sizing the canvas reset the context state; set the font again. */
    ctx.font = px + "px " + FONT;
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    if (img.complete && img.naturalWidth) {
      sample();
      ready = true;
      if (!hovering && !sweep) { lx = wantX = W * 0.5; ly = wantY = H * 0.5; }
      draw();
    }
  }

  /* One frame of the field. The light is a band through (lx, ly) at a
     fixed diagonal: a cell's highlight falls off with its distance across
     the band and, more slowly, along it, so it reads as a spot of glint
     rather than a stripe across the whole box. */
  function draw() {
    if (!ready) return;
    ctx.clearRect(0, 0, W, H);
    var dx = 0.82, dy = -0.57;             /* band direction, ~35° up-right */
    var across = Math.max(34, W * 0.075);  /* band half-width in px */
    var along = Math.max(150, W * 0.42);   /* reach along the band */
    var s = strength, bx = lx, by = ly;
    if (scrollLight && scrollLight.s > s) { s = scrollLight.s; bx = scrollLight.x; by = scrollLight.y; }
    var q = scatter;
    var fade = Math.pow(1 - q, 1.6);
    var reach = Math.max(W, H) * 0.9 * q * q;
    var ox = padX + cw / 2;
    var oy = padY + ch / 2;
    for (var r = 0; r < rows; r++) {
      var y = oy + r * ch;
      for (var c = 0; c < cols; c++) {
        var i = r * cols + c;
        var x = ox + c * cw;
        var k = cover[i];
        if (k < 0.03) {
          /* Off-knot cells: a sparse, still dust, so the dark half of the
             box reads as the same field the knot sits in. */
          if (seed[i] > 0.965) {
            ctx.globalAlpha = 0.07 + 0.07 * seed[i];
            ctx.fillStyle = dust;
            ctx.fillText(".", x, y);
          }
          continue;
        }
        /* Scattering thins the ramp as well as the alpha, so the knot
           dissolves to its outline before it goes. */
        var lvl = Math.floor(k * (1 - q * 0.7) * LAST + 0.5);
        if (lvl < 1) continue;
        var g = 0;
        if (s > 0.004) {
          var vx = x - bx, vy = y - by;
          var a = Math.abs(vx * dy - vy * dx) / across;   /* across the band */
          var b = (vx * dx + vy * dy) / along;            /* along the band */
          g = s * Math.exp(-(a * a) - b * b);
        }
        var gx = x, gy = y;
        if (q > 0) {
          gx += drift[2 * i] * reach;
          gy += drift[2 * i + 1] * reach;
        }
        ctx.globalAlpha = Math.min(1, 0.42 + 0.58 * k + 0.5 * g) * fade;
        ctx.fillStyle = palette[Math.round(Math.min(1, g) * STEPS)];
        ctx.fillText(RAMP.charAt(lvl), gx, gy);
      }
    }
    ctx.globalAlpha = 1;
  }

  /* Advance the light, then decide whether anything is still moving. */
  function step(dt) {
    if (sweep) {
      var t = (performance.now() - sweep.t0) / SWEEP_TAKES;
      if (t >= 1) {
        sweep = null;
        wantStrength = hovering ? 1 : 0;
      } else {
        /* Across the box from the top-left corner to the bottom-right, with
           a soft rise and fall in strength so it arrives and leaves gently. */
        wantX = lx = W * (-0.15 + 1.3 * t);
        wantY = ly = H * (0.05 + 0.9 * t);
        wantStrength = Math.pow(Math.sin(Math.PI * t), 0.7);
      }
    }
    var ease = 1 - Math.exp(-dt * 7);
    lx += (wantX - lx) * ease;
    ly += (wantY - ly) * ease;
    strength += (wantStrength - strength) * (1 - Math.exp(-dt * 4));
    var settled = !sweep &&
      Math.abs(wantStrength - strength) < 0.004 &&
      Math.abs(wantX - lx) < 0.5 && Math.abs(wantY - ly) < 0.5;
    if (settled) strength = wantStrength;
    return !settled;
  }

  function frame(now) {
    raf = 0;
    if (!visible || reduced.matches) return;
    var dt = last ? Math.min(0.05, (now - last) / 1000) : 1 / 60;
    last = now;
    var moving = step(dt);
    draw();
    if (moving) raf = requestAnimationFrame(frame);
    else last = 0;
  }

  function wake() {
    if (raf || !visible || reduced.matches) return;
    last = 0;
    raf = requestAnimationFrame(frame);
  }

  function scheduleSweep(delay) {
    clearTimeout(sweepTimer);
    if (reduced.matches) return;
    sweepTimer = setTimeout(function () {
      if (visible && !hovering && ready && !document.hidden) {
        sweep = { t0: performance.now() };
        wake();
      }
      scheduleSweep(SWEEP_EVERY);
    }, delay);
  }

  img.onload = function () {
    resize();
    scheduleSweep(SWEEP_FIRST);
  };

  readTheme();
  resize();

  if ("ResizeObserver" in window) {
    new ResizeObserver(function () { resize(); }).observe(box);
  } else {
    window.addEventListener("resize", resize);
  }

  if ("IntersectionObserver" in window) {
    new IntersectionObserver(function (entries) {
      visible = entries[0].isIntersecting;
      if (visible) wake();
      else if (raf) { cancelAnimationFrame(raf); raf = 0; }
    }).observe(box);
  }

  new MutationObserver(function () {
    readTheme();
    draw();
  }).observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme"] });

  if (reduced.addEventListener) {
    reduced.addEventListener("change", function () {
      if (reduced.matches) { sweep = null; strength = wantStrength = 0; draw(); }
      else scheduleSweep(SWEEP_EVERY);
    });
  }

  /* The opening scene's hook (home.js). `light` places the band by box
     fractions while the copy dismisses (p in (0,1); outside that the pointer
     and the idle sweep own it again); `scatter` is 0..1. Both redraw at once
     when the frame loop is idle, since they move with the scroll, not time. */
  canvas.goriKnot = {
    light: function (p) {
      var was = !!scrollLight;
      if (p <= 0 || p >= 1 || reduced.matches) scrollLight = null;
      else scrollLight = { x: W * (-0.25 + 1.5 * p), y: H * (-0.05 + 1.1 * p), s: Math.pow(Math.sin(Math.PI * p), 0.6) };
      if ((was || scrollLight) && !raf) draw();
    },
    scatter: function (q) {
      q = q < 0 ? 0 : q > 1 ? 1 : q;
      if (Math.abs(q - scatter) < 0.002) return;
      scatter = q;
      if (!raf) draw();
    }
  };

  if (!reduced.matches) {
    canvas.addEventListener("pointermove", function (ev) {
      /* The stage scales the box with a transform; map back to canvas px. */
      var rect = canvas.getBoundingClientRect();
      var k = rect.width ? W / rect.width : 1;
      wantX = (ev.clientX - rect.left) * k;
      wantY = (ev.clientY - rect.top) * k;
      if (!hovering) {
        hovering = true;
        sweep = null;
        /* Start the band where the pointer is, not where the last sweep
           left it, so the glint appears under the cursor. */
        if (strength < 0.01) { lx = wantX; ly = wantY; }
      }
      wantStrength = 1;
      wake();
    });
    canvas.addEventListener("pointerleave", function () {
      hovering = false;
      wantStrength = 0;
      wake();
    });
  }
})();
