// Size filter for the backlog table. Without JavaScript the whole table is shown.
  var bar = document.querySelector('.filters');
  if (bar) {
    bar.hidden = false;
    var rows = document.querySelectorAll('table.backlog tbody tr');
    bar.addEventListener('click', function (e) {
      var b = e.target.closest('button[data-filter]');
      if (!b) return;
      bar.querySelectorAll('button').forEach(function (x) { x.setAttribute('aria-pressed', String(x === b)); });
      rows.forEach(function (r) { r.hidden = b.dataset.filter !== 'all' && r.dataset.size !== b.dataset.filter; });
    });
  }
