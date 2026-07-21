/* Right-click the top-nav logo mark for brand asset downloads.
   Pattern mirrors herdr.dev: context menu at the cursor with PNG variants
   and a one-click copy of the primary logo URL. */
(function () {
  var menu = document.getElementById("logo-menu");
  var copyButton = document.getElementById("copy-logo-url");
  var logos = document.querySelectorAll(".logo-mark");
  if (!menu || !logos.length) return;

  var copyLabel = copyButton
    ? copyButton.getAttribute("data-label") || copyButton.textContent
    : "";
  var copyCopied = copyButton
    ? copyButton.getAttribute("data-copied") || "Copied"
    : "";
  var copyTimer = null;

  function hideMenu() {
    menu.hidden = true;
  }

  function showMenu(event) {
    event.preventDefault();
    event.stopPropagation();
    menu.hidden = false;
    /* Measure after unhiding so offsetWidth/Height are real. */
    var menuWidth = menu.offsetWidth;
    var menuHeight = menu.offsetHeight;
    var left = Math.min(event.clientX, window.innerWidth - menuWidth - 12);
    var top = Math.min(event.clientY, window.innerHeight - menuHeight - 12);
    menu.style.left = Math.max(12, left) + "px";
    menu.style.top = Math.max(12, top) + "px";
  }

  for (var i = 0; i < logos.length; i++) {
    logos[i].addEventListener("contextmenu", showMenu);
  }

  document.addEventListener("click", function (event) {
    if (!menu.contains(event.target)) hideMenu();
  });
  /* Close after a download choice so the menu does not linger over the page. */
  menu.addEventListener("click", function (event) {
    var item = event.target.closest("a[download]");
    if (item) hideMenu();
  });
  document.addEventListener("keydown", function (event) {
    if (event.key === "Escape") hideMenu();
  });
  window.addEventListener("scroll", hideMenu, { passive: true });
  window.addEventListener("resize", hideMenu);

  if (copyButton) {
    copyButton.addEventListener("click", function () {
      var path = copyButton.getAttribute("data-logo-url") || "/images/gori.png";
      var url = new URL(path, window.location.href).href;

      function done() {
        copyButton.textContent = copyCopied;
        if (copyTimer) clearTimeout(copyTimer);
        copyTimer = setTimeout(function () {
          copyButton.textContent = copyLabel;
        }, 1500);
      }

      function copyLegacy() {
        var ta = document.createElement("textarea");
        ta.value = url;
        ta.style.position = "fixed";
        ta.style.opacity = "0";
        document.body.appendChild(ta);
        ta.select();
        try {
          if (document.execCommand("copy")) done();
          else window.prompt(copyLabel, url);
        } catch (e) {
          window.prompt(copyLabel, url);
        }
        document.body.removeChild(ta);
      }

      if (navigator.clipboard && window.isSecureContext) {
        navigator.clipboard.writeText(url).then(done, copyLegacy);
      } else {
        copyLegacy();
      }
    });
  }
})();
