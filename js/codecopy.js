/* Add a copy button to every fenced code block. The pre is wrapped so the
   button stays pinned to the block's corner instead of scrolling away with
   long lines (pre is its own horizontal scroll container). */
(function () {
  var COPY_ICON = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="9" y="9" width="12" height="12" rx="2.5"/><path d="M5 15H4.5A1.5 1.5 0 0 1 3 13.5v-9A1.5 1.5 0 0 1 4.5 3h9A1.5 1.5 0 0 1 15 4.5V5"/></svg>';
  var CHECK_ICON = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m5 12.5 5 5 9-11"/></svg>';

  function codeText(code) {
    /* Strip line-number spans (.ln) so gutter digits never land in the
       clipboard; textContent of the highlighted spans is the raw source. */
    var clone = code.cloneNode(true);
    var lns = clone.querySelectorAll('.ln');
    for (var i = 0; i < lns.length; i++) lns[i].parentNode.removeChild(lns[i]);
    return clone.textContent.replace(/\n$/, '');
  }

  function copyLegacy(text) {
    /* http:// preview, or clipboard API rejections (focus/permission) */
    return new Promise(function (resolve, reject) {
      var ta = document.createElement('textarea');
      ta.value = text;
      ta.style.position = 'fixed';
      ta.style.opacity = '0';
      document.body.appendChild(ta);
      ta.select();
      try {
        document.execCommand('copy') ? resolve() : reject(new Error('execCommand failed'));
      } catch (e) {
        reject(e);
      } finally {
        document.body.removeChild(ta);
      }
    });
  }

  function copy(text) {
    if (navigator.clipboard && window.isSecureContext) {
      return navigator.clipboard.writeText(text).catch(function () { return copyLegacy(text); });
    }
    return copyLegacy(text);
  }

  var codes = document.querySelectorAll('pre > code');
  for (var i = 0; i < codes.length; i++) {
    (function (code) {
      var pre = code.parentNode;
      var wrap = document.createElement('div');
      wrap.className = 'code-block';
      pre.parentNode.insertBefore(wrap, pre);
      wrap.appendChild(pre);

      var btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'code-copy';
      btn.setAttribute('aria-label', 'Copy code');
      btn.title = 'Copy code';
      btn.innerHTML = COPY_ICON + CHECK_ICON;

      var timer = null;
      btn.addEventListener('click', function () {
        copy(codeText(code)).then(function () {
          btn.classList.add('copied');
          btn.setAttribute('aria-label', 'Copied');
          if (timer) clearTimeout(timer);
          timer = setTimeout(function () {
            btn.classList.remove('copied');
            btn.setAttribute('aria-label', 'Copy code');
          }, 1600);
        }, function () {});
      });
      wrap.appendChild(btn);
    })(codes[i]);
  }
})();
