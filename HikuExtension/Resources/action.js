// The extension's menu in Safari: turn tap-to-look-up on or off, see the dictionaries, and
// (until the App Group lets the Hiku app do it) set AnkiConnect and the deck.
document.addEventListener('DOMContentLoaded', async () => {
  const $ = (id) => document.getElementById(id);
  const toggle = $('enabled');
  toggle.checked = (await browser.storage.local.get('enabled')).enabled !== false;
  toggle.addEventListener('change', () => browser.storage.local.set({enabled: toggle.checked}));
  const japaneseOnly = $('japaneseOnly');
  japaneseOnly.checked = (await browser.storage.local.get('japaneseOnly')).japaneseOnly !== false;
  japaneseOnly.addEventListener('change', () => browser.storage.local.set({japaneseOnly: japaneseOnly.checked}));

  const response = await browser.runtime.sendMessage({action: 'status'});
  if (!response || response.error) {
    $('status').textContent = response?.error ?? 'The app didn’t answer.';
    return;
  }
  const names = response.dictionaries?.join(', ') || 'none';
  const stats = response.stats ?? {};
  $('status').textContent = `Dictionaries: ${names}. Memory ${stats.memoryMB} MB` +
    (stats.prepareMs ? `, prepared in ${(stats.prepareMs / 1000).toFixed(1)} s` : '') + '.' +
    (response.skipped?.length ? ` Couldn\u2019t set up on this device: ${response.skipped.join(', ')}.` : '');

  if (response.managedByApp) {
    $('ankiManaged').hidden = false;
    return;
  }
  const form = $('ankiForm');
  form.hidden = false;
  const deck = $('ankiDeck');
  let currentDeck = response.anki?.deck ?? '';
  if (response.anki) {
    $('ankiURL').value = response.anki.url;
    if (response.anki.hasKey) $('ankiKey').placeholder = 'API key (saved; leave blank to keep)';
    $('ankiResult').textContent = `Saved. Cards go to “${currentDeck}”.`;
  }

  function showDecks(decks, chosen) {
    deck.replaceChildren(...decks.map((name) => new Option(name, name, false, name === chosen)));
    deck.hidden = decks.length === 0;
  }

  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    $('ankiSave').disabled = true;
    $('ankiResult').textContent = 'Checking…';
    const keyField = $('ankiKey').value;
    const result = await browser.runtime.sendMessage({
      action: 'saveAnki', url: $('ankiURL').value,
      // Blank keeps a saved key only if there was one; there's no way to show it back.
      apiKey: keyField || (response.anki?.hasKey ? '\u0000keep' : ''),
      deck: deck.hidden ? currentDeck : deck.value,
    });
    $('ankiSave').disabled = false;
    if (!result || result.error) {
      $('ankiResult').textContent = 'Couldn’t reach AnkiConnect: ' + (result?.error ?? 'no answer');
      return;
    }
    currentDeck = result.deck;
    showDecks(result.decks ?? [], currentDeck);
    $('ankiResult').textContent = `Connected (AnkiConnect v${result.version}). Cards go to “${currentDeck}”` +
      (deck.hidden ? '.' : '; pick another deck above and save again to change it.');
  });
});
