/* The landing hero's ring knot, drawn as a field of monospace glyphs on a
   canvas. The brand mark (images/gori.svg) is sampled once per resize into a
   per-cell coverage grid; each frame maps coverage to a glyph on a density
   ramp, so the knot reads as ASCII art that still has the logo's exact shape.

   Motion is deliberately quiet: a slow sine field breathes across the knot,
   a handful of cells flicker to a neighbouring glyph, and the pointer leaves
   a short wake — energy deposited under the cursor, diffused and decayed each
   frame — that lights the cells it crosses and ripples once on a click.

   Gates: the canvas is aria-hidden decoration over an <img> fallback that
   html.js hides, so no-script visits see the plain mark. Reduced motion draws
   one still frame and skips every listener. Off-screen or in a hidden tab the
   loop stops (IntersectionObserver + requestAnimationFrame). The theme swap
   is picked up from data-theme, so the gold turns bronze on paper. */
(function () {
  var box = document.getElementById("heroArt");
  var canvas = document.getElementById("heroAscii");
  if (!box || !canvas || !canvas.getContext) return;
  var ctx = canvas.getContext("2d");
  if (!ctx) return;

  var RAMP = " .:-=+*#%@";
  var LAST = RAMP.length - 1;
  var FONT = "ui-monospace, \"SF Mono\", \"Cascadia Code\", Menlo, Consolas, monospace";
  var reduced = window.matchMedia("(prefers-reduced-motion: reduce)");

  var cw = 0, ch = 0, cols = 0, rows = 0, px = 13, dpr = 1, padX = 0, padY = 0;
  var cover = new Float32Array(0);   /* logo coverage per cell, 0..1 */
  var seed = new Float32Array(0);    /* per-cell random phase, 0..1 */
  var energy = new Float32Array(0);  /* pointer wake, diffused each frame */
  var energyTmp = new Float32Array(0);
  var ripples = [];                  /* {x, y, born} in cell units */
  var gold = "#c8a860", bright = "#e6cf92", dust = "#c8a860";
  var raf = 0, last = 0, time = 0, visible = true, ready = false;

  var img = new Image();
  img.decoding = "async";
  img.src = canvas.getAttribute("data-src");

  function readTheme() {
    var cs = getComputedStyle(document.documentElement);
    gold = cs.getPropertyValue("--accent").trim() || gold;
    bright = cs.getPropertyValue("--accent-strong").trim() || bright;
    dust = cs.getPropertyValue("--muted").trim() || gold;
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
    energy = new Float32Array(n);
    energyTmp = new Float32Array(n);
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        var sum = 0;
        for (var y = 0; y < ss; y++) {
          var row = ((r * ss + y) * off.width + c * ss) * 4 + 3;
          for (var x = 0; x < ss; x++) sum += data[row + x * 4];
        }
        var i = r * cols + c;
        cover[i] = sum / (ss * ss * 255);
        /* Deterministic hash, so a resize does not reshuffle the flicker. */
        var h = Math.sin(c * 12.9898 + r * 78.233) * 43758.5453;
        seed[i] = h - Math.floor(h);
      }
    }
  }

  function resize() {
    var rect = box.getBoundingClientRect();
    if (rect.width < 1 || rect.height < 1) return;
    dpr = Math.min(window.devicePixelRatio || 1, 2);
    px = rect.width < 360 ? 10 : rect.width < 520 ? 12 : 13;
    ctx.font = px + "px " + FONT;
    /* The real advance of the font that was resolved, so the knot keeps its
       proportions whatever monospace the platform supplies. */
    cw = ctx.measureText("@").width || px * 0.6;
    ch = px * 1.04;
    cols = Math.floor(rect.width / cw);
    rows = Math.floor(rect.height / ch);
    /* Centre the grid: the box is rarely a whole number of cells. */
    padX = (rect.width - cols * cw) / 2;
    padY = (rect.height - rows * ch) / 2;
    canvas.width = Math.round(rect.width * dpr);
    canvas.height = Math.round(rect.height * dpr);
    canvas.style.width = rect.width + "px";
    canvas.style.height = rect.height + "px";
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    /* Sizing the canvas reset the context state; set the font again. */
    ctx.font = px + "px " + FONT;
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    if (img.complete && img.naturalWidth) {
      sample();
      ready = true;
      if (reduced.matches) draw(0);
    }
  }

  function diffuse(dt) {
    var decay = Math.exp(-1.6 * dt);
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        var i = r * cols + c;
        var l = c > 0 ? energy[i - 1] : energy[i];
        var rt = c < cols - 1 ? energy[i + 1] : energy[i];
        var u = r > 0 ? energy[i - cols] : energy[i];
        var d = r < rows - 1 ? energy[i + cols] : energy[i];
        energyTmp[i] = (4 * energy[i] + l + rt + u + d) * 0.125 * decay;
      }
    }
    var t = energy;
    energy = energyTmp;
    energyTmp = t;
  }

  function draw(dt) {
    if (!ready) return;
    time += dt;
    if (dt > 0) diffuse(dt);
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    /* Off-knot cells: a sparse, breathing dust so the dark half of the box
       reads as the same field the knot sits in, not as a frame around it. */
    var ox = padX + cw / 2;
    var oy = padY + ch / 2;
    var i, c, r, x, y;
    for (r = 0; r < rows; r++) {
      y = oy + r * ch;
      for (c = 0; c < cols; c++) {
        i = r * cols + c;
        x = ox + c * cw;
        var k = cover[i];
        var e = energy[i];
        if (k < 0.03) {
          if (e > 0.1) {
            /* The pointer's wake through the dark: a trail of water glyphs. */
            ctx.globalAlpha = Math.min(0.55, (e - 0.1) * 1.2);
            ctx.fillStyle = gold;
            ctx.fillText(e > 0.5 ? "-" : ".", x, y);
          } else if (seed[i] > 0.965) {
            ctx.globalAlpha = 0.07 + 0.07 * Math.sin(time * 0.7 + seed[i] * 40);
            ctx.fillStyle = dust;
            ctx.fillText(".", x, y);
          }
          continue;
        }
        /* The breath: two slow sines across the grid, ±14% of coverage. */
        var n = Math.sin(c * 0.28 + time * 0.8 + Math.sin(r * 0.22 - time * 0.5)) * 0.5 + 0.5;
        var v = k * (0.8 + 0.28 * n) + e * 0.9;
        if (v > 1.2) v = 1.2;
        var lvl = Math.floor(Math.min(1, v) * LAST + 0.5);
        /* A few cells flicker one step along the ramp; the phase comes from
           the cell's own seed so the pattern is still, not a sparkle storm. */
        var f = Math.sin(time * 1.3 + seed[i] * 97.0);
        if (f > 0.985 && lvl < LAST) lvl++;
        else if (f < -0.985 && lvl > 1) lvl--;
        if (lvl < 1) continue;
        ctx.globalAlpha = 0.42 + 0.58 * Math.min(1, v);
        ctx.fillStyle = e > 0.22 ? bright : gold;
        ctx.fillText(RAMP.charAt(lvl), x, y);
      }
    }
    /* Click rings: one expanding circle of edge glyphs, fading as it grows. */
    for (var q = ripples.length - 1; q >= 0; q--) {
      var rp = ripples[q];
      var age = time - rp.born;
      if (age > 1.4) { ripples.splice(q, 1); continue; }
      var rad = age * 22;
      var str = (1 - age / 1.4) * 0.7;
      ctx.globalAlpha = str;
      ctx.fillStyle = bright;
      var steps = Math.max(16, Math.floor(rad * 4));
      for (var s = 0; s < steps; s++) {
        var a = s / steps * Math.PI * 2;
        var gc = Math.round(rp.x + Math.cos(a) * rad * ch / cw);
        var gr = Math.round(rp.y + Math.sin(a) * rad);
        if (gc < 0 || gr < 0 || gc >= cols || gr >= rows) continue;
        var g = Math.abs(Math.cos(a)) > 0.7 ? "|" : Math.abs(Math.sin(a)) > 0.7 ? "-" : (Math.cos(a) * Math.sin(a) > 0 ? "\\" : "/");
        ctx.fillText(g, ox + gc * cw, oy + gr * ch);
      }
    }
    ctx.globalAlpha = 1;
  }

  function frame(now) {
    raf = 0;
    if (!visible || reduced.matches) return;
    var dt = last ? Math.min(0.05, (now - last) / 1000) : 1 / 60;
    last = now;
    draw(dt);
    raf = requestAnimationFrame(frame);
  }

  function schedule() {
    if (raf) cancelAnimationFrame(raf);
    raf = 0;
    last = 0;
    if (reduced.matches) { draw(0); return; }
    if (visible) raf = requestAnimationFrame(frame);
  }

  function cellAt(ev) {
    var rect = canvas.getBoundingClientRect();
    return {
      x: (ev.clientX - rect.left - padX) / cw,
      y: (ev.clientY - rect.top - padY) / ch
    };
  }

  function deposit(ev, amount) {
    var p = cellAt(ev);
    var c0 = Math.floor(p.x), r0 = Math.floor(p.y);
    for (var r = r0 - 1; r <= r0 + 1; r++) {
      for (var c = c0 - 1; c <= c0 + 1; c++) {
        if (c < 0 || r < 0 || c >= cols || r >= rows) continue;
        var w = (c === c0 && r === r0) ? 1 : 0.45;
        var i = r * cols + c;
        energy[i] = Math.min(1.5, energy[i] + amount * w);
      }
    }
  }

  img.onload = function () {
    resize();
    schedule();
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
      schedule();
    }).observe(box);
  }

  new MutationObserver(function () {
    readTheme();
    if (reduced.matches) draw(0);
  }).observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme"] });

  if (reduced.addEventListener) reduced.addEventListener("change", schedule);

  if (!reduced.matches) {
    canvas.addEventListener("pointermove", function (ev) { deposit(ev, 0.32); });
    canvas.addEventListener("pointerdown", function (ev) {
      deposit(ev, 0.9);
      var p = cellAt(ev);
      ripples.push({ x: p.x, y: p.y, born: time });
      if (ripples.length > 4) ripples.shift();
    });
  }
})();
