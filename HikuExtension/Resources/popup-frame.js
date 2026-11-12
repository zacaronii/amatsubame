// The popup inside the page: shows the lookup document it was opened for (by the id in the
// URL fragment, fetched from the background page), plays audio, adds cards to Anki and follows
// glossary links (with Back). Scripts in the document are dropped.
const history = [];

async function show(id, remember) {
  const response = await browser.runtime.sendMessage({action: 'popupDocument', id});
  if (!response?.html) return;
  if (remember && current) history.push(current);
  current = id;
  const parsed = new DOMParser().parseFromString(response.html, 'text/html');
  parsed.querySelectorAll('script').forEach((script) => script.remove());
  document.head.replaceChildren(...[...parsed.head.childNodes].map((node) => document.importNode(node, true)));
  document.body.replaceChildren(...[...parsed.body.childNodes].map((node) => document.importNode(node, true)));
  if (history.length) {
    const back = document.createElement('button');
    back.textContent = '‹ Back';
    back.className = 'popup-back';
    back.style.cssText = 'margin: 8px 12px 0; font: 15px -apple-system; border: 0; background: none; color: #0a84ff;';
    back.addEventListener('click', () => show(history.pop(), false));
    document.body.prepend(back);
  }
  const stats = new URLSearchParams(location.search);
  if (!remember && [...stats.keys()].length) {
    // Prototype: how long it took and the extension's memory, at the bottom.
    const note = document.createElement('p');
    note.style.cssText = 'font: 11px -apple-system; opacity: .6; margin: 12px;';
    note.textContent = [...stats].map(([key, value]) => `${key} ${value}`).join(' · ');
    document.body.append(note);
  }
  window.scrollTo(0, 0);
}
let current = null;

/// A note at the bottom of the popup, with an optional button (Undo).
function say(text, button, duration = 4000) {
  let note = document.getElementById('popup-note');
  if (!note) {
    note = document.createElement('div');
    note.id = 'popup-note';
    note.style.cssText = 'position: fixed; left: 8px; right: 8px; bottom: 8px; padding: 8px 12px; border-radius: 10px;' +
      'background: rgba(0,0,0,.85); color: #fff; font: 14px -apple-system; display: flex; align-items: center; gap: 12px;';
    document.body.append(note);
  }
  const label = document.createElement('span');
  label.style.flex = '1';
  label.textContent = text;
  note.replaceChildren(label);
  if (button) {
    const action = document.createElement('button');
    action.textContent = button.title;
    action.style.cssText = 'border: 0; background: none; color: #4da3ff; font: 600 14px -apple-system;';
    action.addEventListener('click', button.action);
    note.append(action);
  }
  clearTimeout(say.timer);
  say.timer = setTimeout(() => note.remove(), duration);
}

document.addEventListener('click', async (event) => {
  const action = event.target.closest('[data-action]');
  if (action) {
    event.preventDefault();
    const index = Number(action.dataset.index);
    if (action.dataset.action === 'audio') {
      const response = await browser.runtime.sendMessage({action: 'audio', id: current, index});
      if (response?.audio) new Audio(`data:${response.type};base64,${response.audio}`).play().catch((error) => say(String(error)));
      else say(response?.error ?? 'No audio.');
    } else if (action.dataset.action === 'mine') {
      if (action.classList.contains('mined')) return;
      action.disabled = true;
      const response = await browser.runtime.sendMessage({action: 'mine', id: current, index});
      action.disabled = false;
      if (!response?.mined) return say(response?.error ?? 'Couldn’t add the card.');
      // Like the apps: a few seconds to undo, then it's sent.
      action.classList.add('mined');
      const jobId = response.jobId;
      const wait = (response.undoSeconds ?? 5) * 1000;
      let undone = false;
      say('Adding to Anki…', {title: 'Undo', action: async () => {
        undone = true;
        const result = await browser.runtime.sendMessage({action: 'undo', jobId});
        if (result?.undone) action.classList.remove('mined');
        say(result?.undone ? 'Not added.' : 'Too late to undo.');
      }}, wait + 1000);
      setTimeout(async () => {
        if (undone) return;
        const sent = await browser.runtime.sendMessage({action: 'send', jobId});
        say(sent?.sent ? 'Added to Anki.' : (sent?.message ?? sent?.error ?? 'Saved; it goes to Anki later.'));
      }, wait + 300);
    }
    return;
  }
  const link = event.target.closest('a.gloss-link');
  if (link && link.dataset.lookup !== undefined) {
    event.preventDefault();
    const response = await browser.runtime.sendMessage({action: 'query', query: link.dataset.lookup});
    if (response?.id && response.found) show(response.id, true);
    else say(response?.error ?? `No entry for ${link.dataset.lookup}.`);
  } else if (link?.href) {
    event.preventDefault();
    window.open(link.href, '_blank');
  }
});

window.addEventListener('hashchange', () => { history.length = 0; current = null; show(location.hash.slice(1), false); });
document.addEventListener('DOMContentLoaded', () => show(location.hash.slice(1), false));
