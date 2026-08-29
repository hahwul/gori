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
   has no light capture), and a later theme toggle still resolves correctly. */
(function () {
  var tabs = document.getElementById("showcaseTabs");
  var img = document.getElementById("showcaseShot");
  if (!tabs || !img) return;

  var base = img.getAttribute("src").replace(/\/images\/tui\/.*$/, "");
  var buttons = tabs.querySelectorAll("button[data-shot]");

  function pick() {
    for (var i = 0; i < buttons.length; i++) {
      buttons[i].setAttribute("aria-pressed", buttons[i] === this ? "true" : "false");
    }
    var dark = base + "/images/tui/" + this.getAttribute("data-shot") + ".svg";
    var light = document.documentElement.getAttribute("data-theme") === "light";
    /* Reset the theme-swap bookkeeping for the new capture. */
    img.dataset.darkSrc = dark;
    delete img.dataset.noLight;
    img.onerror = light ? function () {
      this.onerror = null;
      this.dataset.noLight = "1";
      this.setAttribute("src", this.dataset.darkSrc);
    } : null;
    img.setAttribute("src", light ? dark.replace("/images/tui/", "/images/tui/light/") : dark);
    img.setAttribute("alt", this.getAttribute("data-alt") || "");
  }

  for (var i = 0; i < buttons.length; i++) buttons[i].addEventListener("click", pick);
})();
