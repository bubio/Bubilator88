/*
 * Apple Help Book — In-page TOC Sidebar
 *
 * Self-contained toggle: does NOT depend on window.HelpViewer API.
 * The nav element and inter-page links are the primary navigation.
 * This script adds a toggle button to show/hide the sidebar.
 */

(function() {
    var nav = document.querySelector('nav[role=navigation]');
    if (!nav) return;

    var content = document.querySelector('.help-content');
    var KEY = 'bubilator88-toc-visible';

    /* Create toggle button */
    var btn = document.createElement('button');
    btn.className = 'toc-toggle';
    btn.setAttribute('aria-label', 'Table of Contents');
    btn.textContent = '\u2630'; /* hamburger ☰ */
    document.body.appendChild(btn);

    function showTOC() {
        nav.setAttribute('aria-hidden', 'false');
        nav.style.display = 'block';
        if (content) content.style.marginLeft = '210px';
        btn.classList.add('active');
        try { sessionStorage.setItem(KEY, '1'); } catch(e) {}
    }

    function hideTOC() {
        nav.setAttribute('aria-hidden', 'true');
        nav.style.display = 'none';
        if (content) content.style.marginLeft = '0';
        btn.classList.remove('active');
        try { sessionStorage.setItem(KEY, '0'); } catch(e) {}
    }

    btn.addEventListener('click', function() {
        if (nav.getAttribute('aria-hidden') === 'true') showTOC();
        else hideTOC();
    });

    /* Highlight current page */
    var links = nav.querySelectorAll('a');
    var path = window.location.pathname;
    for (var i = 0; i < links.length; i++) {
        var href = links[i].getAttribute('href');
        if (href && path.indexOf(href.replace(/^\.\.\//, '')) !== -1) {
            links[i].classList.add('toc-current');
        }
    }

    /* Restore state from previous page */
    try {
        if (sessionStorage.getItem(KEY) === '1') showTOC();
    } catch(e) {}
})();
