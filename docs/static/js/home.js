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
   The strip carries the TUI's full tab order, so it scrolls on narrow
   viewports: the picked tab is scrolled into view, and ←/→ walks the row the
   way the same keys walk tabs in gori itself.

   Swapping `src` directly blanks the frame until the new capture decodes —
   the jank this used to show on a cold cache. So a click decodes FIRST and
   only then assigns, which means the visible frame never goes empty: it holds
   the old screen a beat, then cuts to the new one. */
(function () {
  var tabs = document.getElementById("showcaseTabs");
  var img = document.getElementById("showcaseShot");
  if (!tabs || !img) return;

  var base = img.getAttribute("src").replace(/\/images\/tui\/.*$/, "");
  var buttons = tabs.querySelectorAll("button[data-shot]");
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

  function show(btn, focus) {
    var mine = ++seq;
    for (var i = 0; i < buttons.length; i++) {
      buttons[i].setAttribute("aria-pressed", buttons[i] === btn ? "true" : "false");
    }

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

  function step(from, delta) {
    for (var i = 0; i < buttons.length; i++) {
      if (buttons[i] !== from) continue;
      var next = buttons[i + delta];
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
})();
