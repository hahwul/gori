(function () {
  var rail = document.getElementById('tocRail');
  var main = document.getElementById('main');
  if (!main) return;

  /* Below the three-track layout the rail panels start collapsed: the
     sidebar folds away on phones, the TOC folds away whenever it sits above
     the article instead of beside it. Only the initial state is decided
     here; the reader's own toggles are never overridden. */
  var sidebar = document.querySelector('.sidebar-browser');
  if (sidebar && window.matchMedia('(max-width: 860px)').matches) sidebar.removeAttribute('open');
  var tocCollapsed = window.matchMedia('(max-width: 1199px)').matches;

  if (!rail) return;
  var heads = Array.prototype.slice.call(main.querySelectorAll('h2[id], h3[id]'));
  var anchorLabel = rail.getAttribute('data-anchor') || 'Link to heading';

  /* Hover anchors: every linkable heading gets a quiet # for copyable URLs.
     Runs after the TOC labels are read so the "#" never leaks into them. */
  function addAnchors() {
    heads.forEach(function (h) {
      var a = document.createElement('a');
      a.className = 'h-anchor';
      a.href = '#' + h.id;
      a.setAttribute('aria-label', anchorLabel + ': ' + h.textContent);
      a.textContent = '#';
      h.appendChild(a);
    });
  }

  if (heads.length < 2) {
    addAnchors();
    rail.remove();
    return;
  }

  /* The panel mirrors the sidebar's markup — a <details> with the title on
     its top rule — so both rails share one set of styles. */
  var panel = document.createElement('details');
  panel.className = 'toc-browser tui-panel';
  if (!tocCollapsed) panel.open = true;
  var summary = document.createElement('summary');
  summary.className = 'panel-title';
  var title = document.createElement('span');
  title.textContent = rail.getAttribute('data-title') || 'On this page';
  var toggle = document.createElement('span');
  toggle.className = 'panel-toggle';
  toggle.setAttribute('aria-hidden', 'true');
  summary.appendChild(title);
  summary.appendChild(toggle);
  panel.appendChild(summary);

  var body = document.createElement('div');
  body.className = 'toc-body';
  var nav = document.createElement('nav');
  var ul = document.createElement('ul');
  var sub = null;

  heads.forEach(function (h) {
    var li = document.createElement('li');
    var a = document.createElement('a');
    a.href = '#' + h.id;
    a.textContent = h.textContent;
    a.setAttribute('data-target', h.id);
    li.appendChild(a);
    if (h.tagName === 'H3') {
      if (!sub) {
        sub = document.createElement('ul');
        (ul.lastElementChild || ul).appendChild(sub);
      }
      sub.appendChild(li);
    } else {
      ul.appendChild(li);
      sub = null;
    }
  });

  nav.appendChild(ul);
  body.appendChild(nav);

  var top = document.createElement('a');
  top.className = 'toc-top';
  top.href = '#main';
  top.textContent = rail.getAttribute('data-top') || 'Back to top';
  body.appendChild(top);

  panel.appendChild(body);
  rail.appendChild(panel);
  addAnchors();

  var byId = {};
  Array.prototype.slice.call(rail.querySelectorAll('a[data-target]')).forEach(function (a) {
    byId[a.getAttribute('data-target')] = a;
  });

  /* The active line is the heading's own scroll-margin-top, so a click that
     lands a heading exactly there counts it (a fixed header + 16px sat a few
     pixels above the landing spot, and the row before it lit up instead).
     A couple of pixels of slack absorb sub-pixel scroll positions. */
  var offset = 0;
  function measure() {
    var margin = parseFloat(window.getComputedStyle(heads[0]).scrollMarginTop);
    if (!(margin > 0)) {
      var hdr = document.querySelector('.docs-header');
      margin = (hdr ? hdr.offsetHeight : 64) + 20;
    }
    offset = margin + 2;
  }
  measure();

  /* Keep the cursor row inside the pane's own scroller — the pane scrolls,
     never the page, so a long outline follows the reader without a jump. */
  function reveal(a) {
    var top = a.offsetTop - body.offsetTop;
    var bottom = top + a.offsetHeight;
    if (top < body.scrollTop) body.scrollTop = top - 8;
    else if (bottom > body.scrollTop + body.clientHeight) body.scrollTop = bottom - body.clientHeight + 8;
  }

  var activeId = null;
  function setActive(id) {
    if (id === activeId) return;
    if (activeId && byId[activeId]) byId[activeId].classList.remove('active');
    activeId = id;
    if (id && byId[id]) {
      byId[id].classList.add('active');
      reveal(byId[id]);
    }
  }

  function atBottom() {
    return window.innerHeight + window.scrollY >= document.documentElement.scrollHeight - 4;
  }

  function update() {
    var current = heads[0].id;
    if (atBottom()) {
      current = heads[heads.length - 1].id;
    } else {
      for (var i = 0; i < heads.length; i++) {
        if (heads[i].getBoundingClientRect().top <= offset) current = heads[i].id;
        else break;
      }
    }
    setActive(current);
  }

  var ticking = false;
  function onScroll() {
    if (ticking) return;
    ticking = true;
    window.requestAnimationFrame(function () {
      update();
      ticking = false;
    });
  }

  window.addEventListener('scroll', onScroll, { passive: true });
  window.addEventListener('resize', function () { measure(); update(); });
  rail.addEventListener('click', function (e) {
    var a = e.target.closest('a[data-target]');
    if (a) setActive(a.getAttribute('data-target'));
  });
  update();
})();
