// A copy button on each code block. Everything still works without JavaScript.
  document.querySelectorAll('pre[data-copy]').forEach(function (pre) {
    var button = document.createElement('button');
    button.className = 'copy'; button.type = 'button'; button.textContent = 'COPY';
    button.setAttribute('aria-label', 'Copy these commands');
    button.addEventListener('click', function () {
      var text = pre.innerText.replace(/^COPY\n?/, '');
      (navigator.clipboard ? navigator.clipboard.writeText(text) : Promise.reject()).then(function () {
        button.textContent = 'COPIED'; setTimeout(function () { button.textContent = 'COPY'; }, 1800);
      }).catch(function () { button.textContent = 'SELECT + ⌘C'; });
    });
    pre.appendChild(button);
  });

// Polish: cards glow where the pointer is, and sections fade in as you scroll to them.
(function () {
  document.querySelectorAll('.card, .mode').forEach(function (el) {
    el.addEventListener('pointermove', function (e) {
      var r = el.getBoundingClientRect();
      el.style.setProperty('--mx', (e.clientX - r.left) + 'px');
      el.style.setProperty('--my', (e.clientY - r.top) + 'px');
    });
  });
  var calm = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  if (calm || !('IntersectionObserver' in window)) return;
  var targets = document.querySelectorAll('main section .wrap > *, .cards > *, .guides > *, .modes > *, .gallery > *, .phones > *, .themes > *, .facts > *');
  var io = new IntersectionObserver(function (entries) {
    entries.forEach(function (e) { if (e.isIntersecting) { e.target.classList.add('in'); io.unobserve(e.target); } });
  }, { rootMargin: '0px 0px -6% 0px', threshold: 0.05 });
  targets.forEach(function (el) {
    var sibs = el.parentElement ? Array.prototype.indexOf.call(el.parentElement.children, el) : 0;
    if (el.parentElement && el.parentElement.matches('.cards, .guides, .modes, .gallery, .phones, .themes, .facts')) el.style.setProperty('--i', Math.min(sibs, 6));
    el.classList.add('reveal'); io.observe(el);
  });
})();
