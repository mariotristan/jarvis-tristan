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
