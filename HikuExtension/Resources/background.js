// Relays messages to the native side (Swift: dictionaries, lookup, audio, Anki) and keeps the
// last few popup documents for the popup frame to fetch. The page can't reach runtime
// messaging, so it can't put its own HTML into the extension's popup frame.
const documents = new Map();

function keep(id, html) {
  documents.set(id, html);
  while (documents.size > 8) documents.delete(documents.keys().next().value);
}

const native = (message) => browser.runtime.sendNativeMessage('com.amatsubame.hiku', message)
  .catch((error) => ({error: String(error)}));

browser.runtime.onMessage.addListener((message) => {
  switch (message?.action) {
    case 'popupDocument':
      return Promise.resolve({html: documents.get(message.id) ?? null});
    case 'lookup':
    case 'query':
      // The HTML stays here; the page only gets the id to open the popup frame with.
      return native(message).then((response) => {
        if (!response || response.error) return {error: response?.error ?? 'No answer from the app'};
        if (response.html) keep(response.id, response.html);
        const {html, ...rest} = response;
        return rest;
      });
    case 'audio':
    case 'mine':
    case 'undo':
    case 'send':
    case 'status':
    case 'saveAnki':
    case 'marks':
      return native(message);
  }
});
