// Kaku's page: the sections refresh every 5 s while the tab is showing. Read only for now; the
// CSRF token in <meta name="csrf-token"> goes with every change once the page makes any (M2).
(function () {
  const sections = document.getElementById('sections');
  async function refresh() {
    if (document.hidden) return;
    try {
      const response = await fetch('/ui/sections', { credentials: 'same-origin', cache: 'no-store' });
      if (response.ok) sections.innerHTML = await response.text();
    } catch (error) {
      // Offline for a moment: the next refresh tries again.
    }
  }
  setInterval(refresh, 5000);
  document.addEventListener('visibilitychange', refresh);
})();
