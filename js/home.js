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
