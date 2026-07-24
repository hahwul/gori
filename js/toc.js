(function () {
  var rail = document.getElementById('tocRail');
  var main = document.getElementById('main');
  if (!rail || !main) return;

  var heads = Array.prototype.slice.call(main.querySelectorAll('h2[id], h3[id]'));

  /* Hover anchors: every linkable heading gets a quiet # for copyable URLs.
     Runs after the TOC labels are read so the "#" never leaks into them. */
  function addAnchors() {
    heads.forEach(function (h) {
      var a = document.createElement('a');
      a.className = 'h-anchor';
      a.href = '#' + h.id;
      a.setAttribute('aria-label', 'Link to "' + h.textContent + '"');
      a.textContent = '#';
      h.appendChild(a);
    });
  }

  if (heads.length < 2) {
    addAnchors();
    rail.remove();
    return;
  }

  // Build the list: h2 = top level, h3 nested under the preceding h2.
  var nav = document.createElement('nav');
  var title = document.createElement('p');
  title.className = 'toc-title';
  title.textContent = 'On this page';
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

  nav.appendChild(title);
  nav.appendChild(ul);
  rail.appendChild(nav);
  addAnchors();

  var byId = {};
  Array.prototype.slice.call(rail.querySelectorAll('a[data-target]')).forEach(function (a) {
    byId[a.getAttribute('data-target')] = a;
  });

  var offset = 0;
  function measure() {
    var hdr = document.querySelector('.docs-header');
    offset = (hdr ? hdr.offsetHeight : 64) + 16;
  }
  measure();

  var activeId = null;
  function setActive(id) {
    if (id === activeId) return;
    if (activeId && byId[activeId]) byId[activeId].classList.remove('active');
    activeId = id;
    if (id && byId[id]) byId[id].classList.add('active');
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
