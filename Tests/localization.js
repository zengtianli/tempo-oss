// Exercise the actual popup, including strings that only appear after actions.
const wait = () => new Promise(resolve => setTimeout(resolve, 50));
const chinese = /[\u3400-\u9fff]/;
const remaining = [];
const states = [];
function inspect(state) {
  const text = document.body.innerText.replace(/倍速/g, '');
  const attributes = [...document.querySelectorAll('[title], [placeholder], [aria-label]')]
    .flatMap(e => ['title', 'placeholder', 'aria-label'].map(a => e.getAttribute(a) || ''));
  const strings = [text, ...attributes];
  if (language === 'en') for (const value of strings) if (chinese.test(value)) remaining.push({ state, value });
  states.push({ state, strings });
}
document.getElementById('more').open = true;
await wait();
inspect('settings');
document.getElementById('export').click();
await wait();
inspect('export');
globalThis.__tempoClipboardAllowed = true;
document.getElementById('export').click(); await wait(); inspect('export-copied');
document.getElementById('io').value = 'invalid json';
document.getElementById('import').click();
await wait();
inspect('invalid-import');
const invalidImportShowsError = !!document.getElementById('note').textContent;
document.getElementById('defaults').click();
await wait();
inspect('reset-confirmation');
const key = document.querySelector('#keys button');
key.click(); await wait(); inspect('shortcut-listening');
key.dispatchEvent(new KeyboardEvent('keydown', {code: 'Space', bubbles: true}));
await wait(); inspect('shortcut-space');
key.click(); await wait();
key.dispatchEvent(new KeyboardEvent('keydown', {code: 'Numpad1', bubbles: true}));
await wait(); inspect('shortcut-numpad');
document.dispatchEvent(new CustomEvent('tempo-test:set', {detail: JSON.stringify({rules: {'bilibili.com': 2}, enabled: false})}));
await wait(); inspect('site-rule-disabled');
const clipping = [...document.querySelectorAll('button, summary, .host')].filter(e =>
  e.clientWidth && e.scrollWidth > e.clientWidth + 2).map(e => e.textContent);
const missing = [...document.querySelectorAll('[data-i18n]')].filter(e => !e.textContent.trim()).map(e => e.dataset.i18n);
return JSON.stringify({ok: !remaining.length && !clipping.length && !missing.length && invalidImportShowsError,
  language, remaining, clipping, missing, invalidImportShowsError, states});
