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
   way the same keys walk tabs in gori itself. */
(function () {
  var tabs = document.getElementById("showcaseTabs");
  var img = document.getElementById("showcaseShot");
  if (!tabs || !img) return;

  var base = img.getAttribute("src").replace(/\/images\/tui\/.*$/, "");
  var buttons = tabs.querySelectorAll("button[data-shot]");

  function srcFor(shot, light) {
    var dark = base + "/images/tui/" + shot + ".svg";
    return light ? dark.replace("/images/tui/", "/images/tui/light/") : dark;
  }

  /* Fetch the captures once the page is idle, so the first few tab clicks
     paint from cache instead of flashing an empty frame. Both themes are
     warmed: the toggle is one click away and the twin is the same weight. */
  function preload() {
    for (var i = 0; i < buttons.length; i++) {
      var shot = buttons[i].getAttribute("data-shot");
      new Image().src = srcFor(shot, false);
      new Image().src = srcFor(shot, true);
    }
  }

  if ("requestIdleCallback" in window) {
    requestIdleCallback(preload, { timeout: 2500 });
  } else {
    window.addEventListener("load", function () { setTimeout(preload, 900); });
  }

  function show(btn, focus) {
    for (var i = 0; i < buttons.length; i++) {
      buttons[i].setAttribute("aria-pressed", buttons[i] === btn ? "true" : "false");
    }
    var light = document.documentElement.getAttribute("data-theme") === "light";
    var dark = srcFor(btn.getAttribute("data-shot"), false);
    /* Reset the theme-swap bookkeeping for the new capture. */
    img.dataset.darkSrc = dark;
    delete img.dataset.noLight;
    img.onerror = light ? function () {
      this.onerror = null;
      this.dataset.noLight = "1";
      this.setAttribute("src", this.dataset.darkSrc);
    } : null;
    img.setAttribute("src", light ? dark.replace("/images/tui/", "/images/tui/light/") : dark);
    img.setAttribute("alt", btn.getAttribute("data-alt") || "");

    /* Keep the picked tab on screen when the strip is scrolled. */
    if (btn.scrollIntoView) {
      btn.scrollIntoView({ block: "nearest", inline: "nearest" });
    }
    if (focus) btn.focus();
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
