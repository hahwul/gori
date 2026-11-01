(function () {
  // Only overflowing tables/code join the tab order, so keyboard readers can
  // scroll them without adding dozens of stops to a wide reference page.
  var scrollables = document.querySelectorAll('.document-body pre, .document-body table');
  if ('ResizeObserver' in window) {
    var observer = new ResizeObserver(function (entries) {
      entries.forEach(function (entry) {
        var element = entry.target;
        if (element.scrollWidth > element.clientWidth) element.tabIndex = 0;
        else element.removeAttribute('tabindex');
      });
    });
    scrollables.forEach(function (element) { observer.observe(element); });
  } else {
    scrollables.forEach(function (element) { element.tabIndex = 0; });
  }
  var navigation = document.querySelector('.docs-navigation');
  if (!navigation) return;
  var mobile = window.matchMedia('(max-width: 860px)');
  function syncNavigation() { navigation.open = !mobile.matches; }
  syncNavigation();
  navigation.dataset.ready = "true";
  mobile.addEventListener('change', syncNavigation);
  navigation.addEventListener('keydown', function (event) {
    if (event.key === 'Escape' && mobile.matches && navigation.open) {
      navigation.open = false;
      navigation.querySelector('summary').focus();
    }
  });
})();
