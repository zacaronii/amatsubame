// Kaku's page: the sections refresh every 5 s while the tab is showing, and its buttons send their
// change with the page's CSRF token (<meta name="csrf-token">); the answer is the sections, redrawn.
(function () {
  const sections = document.getElementById('sections');
  const token = document.querySelector('meta[name="csrf-token"]').content;
  let busy = false;

  async function refresh() {
    if (document.hidden || busy) return;
    try {
      const view = encodeURIComponent(sections.dataset.view || '');
      const response = await fetch(`/ui/sections?view=${view}`, { credentials: 'same-origin', cache: 'no-store' });
      if (response.ok) sections.innerHTML = await response.text();
    } catch (error) {
      // Offline for a moment: the next refresh tries again.
    }
  }

  async function act(button) {
    const data = button.dataset;
    if (data.confirm && !window.confirm(data.confirm)) return;
    busy = true;
    button.disabled = true;
    try {
      const response = await fetch('/ui/api/action', {
        method: 'POST',
        credentials: 'same-origin',
        headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': token },
        body: JSON.stringify({
          action: data.action, itemId: data.item || '', episodeId: data.episode || '', libraryId: data.library || '',
          value: data.value || '', view: sections.dataset.view || '',
        }),
      });
      if (response.ok) {
        sections.innerHTML = await response.text();
      } else {
        const problem = await response.json().catch(() => ({}));
        window.alert(problem.detail || `Kaku answered ${response.status}.`);
      }
    } catch (error) {
      window.alert('Kaku couldn’t be reached.');
    } finally {
      busy = false;
      button.disabled = false;
      refresh();
    }
  }

  sections.addEventListener('click', (event) => {
    const button = event.target.closest('button[data-action]');
    if (button) act(button);
  });
  setInterval(refresh, 5000);
  document.addEventListener('visibilitychange', refresh);
})();
