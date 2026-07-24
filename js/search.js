(function () {
  var searchData = null;
  var activeIndex = -1;
  var overlay = document.getElementById('searchOverlay');
  var input = document.getElementById('searchInput');
  var resultsEl = document.getElementById('searchResults');

  function loadSearchData(cb) {
    if (searchData) return cb(searchData);
    var link = document.querySelector('link[rel="stylesheet"][href*="/css/"]');
    var path = link ? new URL(link.href, document.baseURI).pathname : '/css/';
    var searchUrl = path.substring(0, path.indexOf('/css/')) + '/search.json';
    fetch(searchUrl)
      .then(function (r) { return r.json(); })
      .then(function (data) { searchData = data; cb(data); })
      .catch(function () { searchData = []; cb([]); });
  }

  window.openSearch = function () {
    overlay.classList.add('active');
    document.documentElement.classList.add('search-lock');
    input.value = '';
    resultsEl.innerHTML = '';
    activeIndex = -1;
    input.focus();
    loadSearchData(function () {});
  };

  window.closeSearch = function () {
    overlay.classList.remove('active');
    document.documentElement.classList.remove('search-lock');
    activeIndex = -1;
  };

  document.addEventListener('keydown', function (e) {
    if ((e.metaKey || e.ctrlKey) && e.key === 'k') {
      e.preventDefault();
      if (overlay.classList.contains('active')) {
        closeSearch();
      } else {
        openSearch();
      }
    }
    if (e.key === 'Escape' && overlay.classList.contains('active')) {
      closeSearch();
    }
  });

  function escapeHtml(s) {
    var d = document.createElement('div');
    d.textContent = s;
    return d.innerHTML;
  }

  function escapeRegExp(s) {
    return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  }

  function terms(query) {
    return query.trim().toLowerCase().split(/\s+/).filter(Boolean);
  }

  function highlightMatch(text, query) {
    var ts = terms(query);
    if (!ts.length) return escapeHtml(text);
    var re = new RegExp('(' + ts.map(escapeRegExp).join('|') + ')', 'gi');
    return escapeHtml(text).replace(re, '<mark>$1</mark>');
  }

  /* Rank a page for the query, or return -1 when some term is missing.
     Title hits always dominate content hits; within each band an earlier
     match ranks higher. Word-start title matches get an extra nudge so
     "install" puts "Installation" first, not last. */
  function scoreItem(item, ts) {
    var title = item.title.toLowerCase();
    var content = item.content.toLowerCase();
    var score = 0;
    for (var i = 0; i < ts.length; i++) {
      var t = ts[i];
      var ti = title.indexOf(t);
      var ci = content.indexOf(t);
      if (ti === -1 && ci === -1) return -1;
      if (ti !== -1) {
        score += 1000 - Math.min(ti, 100);
        if (ti === 0 || /[^a-z0-9]/.test(title.charAt(ti - 1))) score += 200;
        if (title === t) score += 400;
      } else {
        score += 100 - Math.min(90, Math.floor(ci / 24));
      }
    }
    return score;
  }

  function getSnippet(content, ts) {
    var lower = content.toLowerCase();
    var idx = -1;
    for (var i = 0; i < ts.length; i++) {
      var found = lower.indexOf(ts[i]);
      if (found !== -1 && (idx === -1 || found < idx)) idx = found;
    }
    var qlen = idx === -1 ? 0 : ts[0].length;
    if (idx === -1) idx = 0;
    var start = Math.max(0, idx - 60);
    var end = Math.min(content.length, idx + qlen + 100);
    var snippet = content.substring(start, end).replace(/\s+/g, ' ').trim();
    if (start > 0) snippet = '...' + snippet;
    if (end < content.length) snippet = snippet + '...';
    return snippet;
  }

  function search(query) {
    var ts = terms(query);
    if (!searchData || !ts.length) {
      resultsEl.innerHTML = '';
      activeIndex = -1;
      return;
    }
    var pageLang = document.documentElement.lang || '';
    var results = [];
    for (var i = 0; i < searchData.length; i++) {
      var item = searchData[i];
      if (pageLang && item.lang && item.lang !== pageLang) continue;
      var score = scoreItem(item, ts);
      if (score >= 0) results.push({ item: item, score: score });
    }
    results.sort(function (a, b) { return b.score - a.score; });
    results = results.slice(0, 10);

    if (results.length === 0) {
      resultsEl.innerHTML = '<div class="search-no-results">No results for "' + escapeHtml(query) + '"</div>';
      activeIndex = -1;
      return;
    }

    var html = '';
    for (var j = 0; j < results.length; j++) {
      var r = results[j].item;
      var snippet = getSnippet(r.content, ts);
      html += '<a class="search-result-item" href="' + encodeURI(r.url) + '" data-index="' + j + '">'
        + '<div class="search-result-title">' + highlightMatch(r.title, query) + '</div>'
        + '<div class="search-result-snippet">' + highlightMatch(snippet, query) + '</div>'
        + '</a>';
    }
    html += '<div class="search-hint"><span><kbd>&uarr;</kbd><kbd>&darr;</kbd> navigate</span><span><kbd>Enter</kbd> open</span><span><kbd>ESC</kbd> close</span></div>';
    resultsEl.innerHTML = html;
    activeIndex = -1;
  }

  function updateActive() {
    var items = resultsEl.querySelectorAll('.search-result-item');
    for (var i = 0; i < items.length; i++) {
      items[i].classList.toggle('active', i === activeIndex);
    }
    if (activeIndex >= 0 && items[activeIndex]) {
      items[activeIndex].scrollIntoView({ block: 'nearest' });
    }
  }

  if (input) {
    input.addEventListener('input', function () {
      loadSearchData(function () { search(input.value); });
    });

    input.addEventListener('keydown', function (e) {
      var items = resultsEl.querySelectorAll('.search-result-item');
      var count = items.length;
      if (e.key === 'ArrowDown') {
        e.preventDefault();
        if (!count) return;
        activeIndex = (activeIndex + 1) % count;
        updateActive();
      } else if (e.key === 'ArrowUp') {
        e.preventDefault();
        if (!count) return;
        activeIndex = (activeIndex - 1 + count) % count;
        updateActive();
      } else if (e.key === 'Enter') {
        e.preventDefault();
        if (activeIndex >= 0 && items[activeIndex]) {
          window.location.href = items[activeIndex].href;
        } else if (items.length > 0) {
          window.location.href = items[0].href;
        }
      }
    });
  }
})();
