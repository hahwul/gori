/* Landing-page scroll reveals: flip .in on each .rv element as it enters the
   viewport, so the sections below the fold animate when they are actually
   seen (the hero animates on load from CSS alone). Everything these classes
   hide sits behind html.js and prefers-reduced-motion in the stylesheet, so
   without this script, or with motion off, the page renders complete. */
(function () {
  var main = document.querySelector(".home-main");
  if (!main) return;
  var targets = main.querySelectorAll(".rv");
  if (!targets.length) return;

  function showAll() {
    for (var i = 0; i < targets.length; i++) targets[i].classList.add("in");
  }

  if (!("IntersectionObserver" in window)) {
    showAll();
    return;
  }

  var io = new IntersectionObserver(function (entries) {
    for (var i = 0; i < entries.length; i++) {
      if (!entries[i].isIntersecting) continue;
      entries[i].target.classList.add("in");
      io.unobserve(entries[i].target);
    }
  }, { rootMargin: "0px 0px -10% 0px", threshold: 0.1 });

  for (var i = 0; i < targets.length; i++) io.observe(targets[i]);

  /* Print never scrolls, so the observer would leave everything below the
     fold hidden; resolve it all before the page is laid out for paper. */
  window.addEventListener("beforeprint", showAll);
})();

/* Showcase tabs: each button names a real TUI capture; clicking swaps the
   framed screenshot to that tab's SVG. The theme-swap in footer.html keys off
   img.dataset.darkSrc, so the swap rewrites that too — a tab picked under the
   light theme loads the light twin directly (falling back to dark if a shot
   has no light capture), and a later theme toggle still resolves correctly.
   The strip is the TUI's bar: nine numbered slots and the `0:Tabs` stop. The
   stop opens the same list the `0` key opens, and picking a tab from it lands
   that tab on the far right of the strip WITHOUT a number, exactly as gori
   force-shows an off-bar tab you jumped to. ←/→ walks the row the way the same
   keys walk tabs in gori itself, and the picked tab is scrolled into view.

   Swapping `src` directly blanks the frame until the new capture decodes —
   the jank this used to show on a cold cache. So a click decodes FIRST and
   only then assigns, which means the visible frame never goes empty: it holds
   the old screen a beat, then cuts to the new one. */
(function () {
  var tabs = document.getElementById("showcaseTabs");
  var img = document.getElementById("showcaseShot");
  if (!tabs || !img) return;

  var goto_ = document.getElementById("showcaseGoto");
  var more = document.getElementById("showcaseMore");
  var temp = document.getElementById("showcaseTemp");

  var base = img.getAttribute("src").replace(/\/images\/tui\/.*$/, "");
  /* Every shot button, the `0` list included — preload and the pressed-state
     sweep both want all of them. ←/→ walks the strip alone (see `step`). */
  var buttons = document.querySelectorAll(
    "#showcaseTabs button[data-shot], #showcaseGoto button[data-shot]"
  );
  /* Monotonic click id: a slow decode that resolves after a later click must
     not overwrite the newer capture. */
  var seq = 0;

  function srcFor(shot, light) {
    var dark = base + "/images/tui/" + shot + ".svg";
    return light ? dark.replace("/images/tui/", "/images/tui/light/") : dark;
  }

  function isLight() {
    return document.documentElement.getAttribute("data-theme") === "light";
  }

  /* Warm the captures in the background so a click is a cache hit. Sequential,
     not 24 parallel requests: the first click usually lands within a second of
     the section scrolling into view, and a burst would put the tab the reader
     actually wants behind everything else in the queue. Neighbours of the
     active tab come first for the same reason. */
  function preload() {
    var order = [], i;
    for (i = 0; i < buttons.length; i++) order.push(buttons[i].getAttribute("data-shot"));
    var light = isLight();
    var queue = [];
    for (i = 0; i < order.length; i++) queue.push(srcFor(order[i], light));
    /* The other theme is only needed if the reader toggles; fetch it after. */
    for (i = 0; i < order.length; i++) queue.push(srcFor(order[i], !light));

    var n = 0;
    (function pump() {
      if (n >= queue.length) return;
      var im = new Image();
      im.onload = im.onerror = pump;
      im.src = queue[n++];
    })();
  }

  if ("requestIdleCallback" in window) {
    requestIdleCallback(preload, { timeout: 1200 });
  } else {
    window.addEventListener("load", function () { setTimeout(preload, 400); });
  }

  /* A tab picked out of the `0` list rides the far right of the strip without a
     number until another tab is picked — the temporary tenth tab, which is what
     gori itself draws for an off-bar tab you jumped to. */
  function forceShow(btn) {
    if (!temp) return;
    if (!btn || btn.parentNode !== goto_) {
      temp.hidden = true;
      temp.removeAttribute("data-shot");
      return;
    }
    var name = btn.querySelector("b");
    temp.textContent = name ? name.textContent : btn.textContent.trim();
    temp.setAttribute("data-shot", btn.getAttribute("data-shot"));
    temp.setAttribute("data-alt", btn.getAttribute("data-alt") || "");
    temp.hidden = false;
  }

  function closeGoto(focusMore) {
    if (!goto_ || goto_.hidden) return;
    goto_.hidden = true;
    if (more) more.setAttribute("aria-expanded", "false");
    if (focusMore && more) more.focus();
  }

  function show(btn, focus) {
    var mine = ++seq;
    for (var i = 0; i < buttons.length; i++) {
      buttons[i].setAttribute("aria-pressed", buttons[i] === btn ? "true" : "false");
    }
    if (btn !== temp) forceShow(btn);
    if (temp) temp.setAttribute("aria-pressed", temp.hidden ? "false" : "true");
    closeGoto(false);

    var light = isLight();
    var dark = srcFor(btn.getAttribute("data-shot"), false);
    var want = light ? srcFor(btn.getAttribute("data-shot"), true) : dark;
    var alt = btn.getAttribute("data-alt") || "";

    /* Keep the picked tab on screen when the strip is scrolled. */
    if (btn.scrollIntoView) {
      btn.scrollIntoView({ block: "nearest", inline: "nearest" });
    }
    if (focus) btn.focus();

    function commit(src, noLight) {
      if (mine !== seq) return; /* a newer click already won */
      /* Reset the theme-swap bookkeeping for the new capture. */
      img.dataset.darkSrc = dark;
      if (noLight) img.dataset.noLight = "1"; else delete img.dataset.noLight;
      img.setAttribute("src", src);
      img.setAttribute("alt", alt);
      /* Restart the cut animation: re-assigning src does not. */
      img.classList.remove("is-cut");
      void img.offsetWidth;
      img.classList.add("is-cut");
    }

    /* Decode off-screen, then swap. A decode failure on the light twin means
       that shot has no light capture — fall back to the dark one, which is
       exactly what the theme-swap in footer.html does. */
    var probe = new Image();
    probe.src = want;
    if (!probe.decode) { commit(want, false); return; }
    probe.decode().then(function () {
      commit(want, false);
    }).catch(function () {
      if (want === dark) { commit(dark, false); return; }
      var fb = new Image();
      fb.src = dark;
      var done = function () { commit(dark, true); };
      if (fb.decode) fb.decode().then(done).catch(done); else done();
    });
  }

  /* ←/→ walk the STRIP — the nine slots plus whichever tab the `0` list put at
     the end — not the list behind the stop. The stop itself is not a tab, so
     the arrows stop at the last chip rather than landing on it. */
  function step(from, delta) {
    var row = tabs.querySelectorAll("button[data-shot]:not([hidden])");
    for (var i = 0; i < row.length; i++) {
      if (row[i] !== from) continue;
      var next = row[i + delta];
      if (next) show(next, true);
      return;
    }
  }

  for (var i = 0; i < buttons.length; i++) {
    buttons[i].addEventListener("click", function () { show(this, false); });
    buttons[i].addEventListener("keydown", function (e) {
      if (e.key === "ArrowRight") { step(this, 1); e.preventDefault(); }
      else if (e.key === "ArrowLeft") { step(this, -1); e.preventDefault(); }
    });
  }

  if (temp) {
    temp.addEventListener("click", function () { show(this, false); });
    temp.addEventListener("keydown", function (e) {
      if (e.key === "ArrowRight") { step(this, 1); e.preventDefault(); }
      else if (e.key === "ArrowLeft") { step(this, -1); e.preventDefault(); }
    });
  }

  if (more && goto_) {
    more.addEventListener("click", function () {
      var open = goto_.hidden;
      goto_.hidden = !open;
      more.setAttribute("aria-expanded", open ? "true" : "false");
      if (open) {
        var first = goto_.querySelector("button[data-shot]");
        if (first) first.focus();
      }
    });
    /* esc closes it and hands focus back to the key that opened it, like the
       card in the TUI; a click anywhere else closes it too. */
    goto_.addEventListener("keydown", function (e) {
      if (e.key === "Escape") { closeGoto(true); e.preventDefault(); }
    });
    more.addEventListener("keydown", function (e) {
      if (e.key === "Escape") { closeGoto(true); e.preventDefault(); }
    });
    document.addEventListener("click", function (e) {
      if (goto_.hidden) return;
      if (goto_.contains(e.target) || more.contains(e.target)) return;
      closeGoto(false);
    });
  }
})();

/* Flow walkthrough: light the step whose capture is crossing the middle of
   the viewport. A thin band at the centre line is the trigger, so exactly one
   capture is inside it at a time while scrolling through the section. Pure
   state, no animation of its own: the transitions live in the stylesheet
   (and collapse under reduced motion). Without IntersectionObserver the first
   step simply stays lit. */
(function () {
  var flow = document.querySelector(".home-flow");
  if (!flow || !("IntersectionObserver" in window)) return;
  var shots = flow.querySelectorAll(".flow-shot[data-step]");
  var steps = flow.querySelectorAll(".flow-steps li[data-step]");

  function activate(step) {
    var i;
    for (i = 0; i < shots.length; i++) {
      shots[i].classList.toggle("is-active", shots[i].getAttribute("data-step") === step);
    }
    for (i = 0; i < steps.length; i++) {
      steps[i].classList.toggle("is-active", steps[i].getAttribute("data-step") === step);
    }
  }

  var io = new IntersectionObserver(function (entries) {
    for (var i = 0; i < entries.length; i++) {
      if (entries[i].isIntersecting) activate(entries[i].target.getAttribute("data-step"));
    }
  }, { rootMargin: "-45% 0px -45% 0px", threshold: 0 });

  for (var i = 0; i < shots.length; i++) io.observe(shots[i]);
})();

/* The opening scene. While .home-opening is the pinned stage (the stylesheet
   decides that: wide, tall, motion allowed), scrolling through it scrubs two
   numbers onto it: --p1, the copy dismissing and the knot centring, and --p2,
   the knot scattering and the terminal rising. The knot's canvas takes the
   same numbers through canvas.goriKnot. Where the stage is not pinned the
   sticky test fails and nothing here runs, so the plain flow stays plain. */
(function () {
  var opening = document.getElementById("opening");
  var stage = opening && opening.querySelector(".home-stage");
  var art = opening && opening.querySelector(".hero-art");
  var canvas = document.getElementById("heroAscii");
  if (!opening || !stage || !art) return;

  function pinned() {
    return getComputedStyle(stage).position === "sticky";
  }

  function smooth(a, b, x) {
    var t = (x - a) / (b - a);
    t = t < 0 ? 0 : t > 1 ? 1 : t;
    return t * t * (3 - 2 * t);
  }

  /* Where the knot has to travel to sit in the middle of the stage. Measured
     with the transform taken off, so the answer does not drift with --p1. */
  function measure() {
    var p1 = opening.style.getPropertyValue("--p1");
    opening.style.setProperty("--p1", "0");
    var s = stage.getBoundingClientRect(), a = art.getBoundingClientRect();
    opening.style.setProperty("--art-dx", (s.left + s.width / 2 - (a.left + a.width / 2)) + "px");
    opening.style.setProperty("--art-dy", (s.top + s.height / 2 - (a.top + a.height / 2)) + "px");
    if (p1) opening.style.setProperty("--p1", p1);
  }

  var ticking = false, last = -1;
  function update() {
    ticking = false;
    if (!pinned()) {
      if (last !== -1) {
        last = -1;
        opening.style.removeProperty("--p1");
        opening.style.removeProperty("--p2");
        opening.classList.remove("is-pre", "is-live", "is-dismissed");
        if (canvas && canvas.goriKnot) { canvas.goriKnot.light(0); canvas.goriKnot.scatter(0); }
      }
      return;
    }
    var top = opening.getBoundingClientRect().top + window.scrollY;
    var travel = opening.offsetHeight - stage.offsetHeight;
    var p = travel > 0 ? (window.scrollY - top) / travel : 0;
    p = p < 0 ? 0 : p > 1 ? 1 : p;
    if (p === last) return;
    last = p;
    var p1 = smooth(0, 0.42, p);
    var p2 = smooth(0.38, 0.86, p);
    opening.style.setProperty("--p1", p1.toFixed(4));
    opening.style.setProperty("--p2", p2.toFixed(4));
    opening.classList.toggle("is-pre", p2 < 0.02);
    opening.classList.toggle("is-live", p2 > 0.95);
    opening.classList.toggle("is-dismissed", p1 > 0.6);
    if (canvas && canvas.goriKnot) {
      canvas.goriKnot.light(p1);
      canvas.goriKnot.scatter(p2);
    }
  }

  function schedule() {
    if (ticking) return;
    ticking = true;
    requestAnimationFrame(update);
  }

  window.addEventListener("scroll", schedule, { passive: true });
  window.addEventListener("resize", function () { measure(); last = -1; schedule(); });
  measure();
  update();
  /* The art box settles after fonts and the first layout; measure again. */
  window.addEventListener("load", function () { measure(); last = -1; schedule(); });
})();

/* The section index on the right: light the stop whose section is crossing
   the middle of the viewport, and land a click on the showcase at the end of
   the opening's pin, where the terminal is actually standing. */
(function () {
  var index = document.getElementById("homeIndex");
  if (!index || !("IntersectionObserver" in window)) return;
  var links = index.querySelectorAll("a[href^='#']");
  var byId = {};
  var i;
  for (i = 0; i < links.length; i++) byId[links[i].getAttribute("href").slice(1)] = links[i];

  function current(id) {
    for (var k in byId) {
      if (k === id) byId[k].setAttribute("aria-current", "true");
      else byId[k].removeAttribute("aria-current");
    }
  }

  var opening = document.getElementById("opening");
  var io = new IntersectionObserver(function (entries) {
    for (var j = 0; j < entries.length; j++) {
      if (!entries[j].isIntersecting) continue;
      var el = entries[j].target;
      current(el === opening ? "workbench" : el.id);
    }
  }, { rootMargin: "-40% 0px -55% 0px", threshold: 0 });

  for (var id in byId) {
    var target = id === "workbench" && opening ? opening : document.getElementById(id);
    if (target) io.observe(target);
  }

  if (opening) {
    byId.workbench.addEventListener("click", function (ev) {
      var stage = opening.querySelector(".home-stage");
      if (!stage || getComputedStyle(stage).position !== "sticky") return;
      ev.preventDefault();
      var top = opening.getBoundingClientRect().top + window.scrollY;
      window.scrollTo({ top: top + opening.offsetHeight - stage.offsetHeight, behavior: "smooth" });
    });
  }
})();
