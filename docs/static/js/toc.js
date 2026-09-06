(function () {
  var rail = document.getElementById('tocRail');
  var main = document.getElementById('main');
  if (!rail || !main) return;
  var heads = Array.prototype.slice.call(main.querySelectorAll('h2[id], h3[id]'));
  var placeholder = main.querySelector('.toc-placeholder');
  var title = rail.dataset.title || 'On this page';
  var links = {};
  var disclosure = document.createElement('details');
  disclosure.className = 'toc-disclosure';
  var summary = document.createElement('summary');
  summary.className = 'toc-title';
  summary.textContent = title;
  disclosure.appendChild(summary);
  var nav = document.createElement('nav');
  nav.setAttribute('aria-label', title);
  var list = document.createElement('ul');
  var sub = null;

  heads.forEach(function (heading) {
    var item = document.createElement('li');
    var link = document.createElement('a');
    link.href = '#' + heading.id;
    link.textContent = heading.textContent;
    link.dataset.target = heading.id;
    links[heading.id] = link;
    item.appendChild(link);
    if (heading.tagName === 'H3' && list.lastElementChild) {
      if (!sub) {
        sub = document.createElement('ul');
        list.lastElementChild.appendChild(sub);
      }
      sub.appendChild(item);
    } else {
      list.appendChild(item);
      sub = null;
    }
    var anchor = document.createElement('a');
    anchor.className = 'h-anchor';
    anchor.href = '#' + heading.id;
    anchor.setAttribute('aria-label', heading.textContent);
    anchor.textContent = '#';
    heading.appendChild(anchor);
  });
  if (heads.length < 2) { rail.remove(); if (placeholder) placeholder.remove(); return; }
  nav.appendChild(list);
  disclosure.appendChild(nav);
  rail.appendChild(disclosure);

  // A desktop rail becomes an in-page disclosure on smaller screens.
  // Its content and links remain the same when the viewport changes.
  var marker = document.createComment('table of contents');
  rail.before(marker);
  var compact = window.matchMedia('(max-width: 1199px)');
  function placeContents() {
    if (compact.matches) {
      var heading = main.querySelector('.document-heading');
      if (placeholder) placeholder.after(rail);
      else if (heading) heading.after(rail);
    } else {
      marker.after(rail);
    }
    if (placeholder) placeholder.hidden = true;
    disclosure.open = !compact.matches;
  }
  placeContents();
  compact.addEventListener('change', placeContents);

  var active = null;
  function activate(id) {
    if (active === id) return;
    if (links[active]) { links[active].classList.remove('active'); links[active].removeAttribute('aria-current'); }
    active = id;
    if (links[id]) { links[id].classList.add('active'); links[id].setAttribute('aria-current', 'location'); }
  }
  // Reconcile headings only when a section crosses the reading line. Reading
  // their current positions here also handles jumps over several sections;
  // cached positions would be stale after a jump in the opposite direction.
  var observer;
  function observeHeadings() {
    if (observer) observer.disconnect();
    var header = document.querySelector('.docs-header');
    var offset = (header ? header.offsetHeight : 68) + 24;
    observer = new IntersectionObserver(function () {
      var current = heads[0];
      heads.forEach(function (heading) {
        if (heading.getBoundingClientRect().top <= offset) current = heading;
      });
      activate(current.id);
    }, { rootMargin: '0px 0px -' + Math.max(0, window.innerHeight - offset) + 'px 0px', threshold: 0 });
    heads.forEach(function (heading) { observer.observe(heading); });
  }
  observeHeadings();
  window.addEventListener('resize', observeHeadings);
  rail.addEventListener('click', function (event) {
    var link = event.target.closest('a[data-target]');
    if (link) activate(link.dataset.target);
  });
  var initial = heads[0].id;
  try { initial = decodeURIComponent(window.location.hash.slice(1)) || initial; } catch (error) {}
  activate(links[initial] ? initial : heads[0].id);
})();
