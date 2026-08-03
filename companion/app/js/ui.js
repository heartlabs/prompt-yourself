// Tiny screen "router" + shared UI helpers. No framework, no magic:
// every screen is a <section>; exactly one is visible.

const screens = () => document.querySelectorAll('body > section');

/** Per-screen hooks, registered by the screen modules: { onShow(params) } */
const hooks = {};

export function registerScreen(id, hook) {
  hooks[id] = hook;
}

export function showScreen(id, params = {}) {
  for (const s of screens()) s.hidden = s.id !== id;
  window.scrollTo(0, 0);
  hooks[id]?.onShow?.(params);
}

/** Wire every element with data-nav="screen-id" to navigate on click. */
export function wireNavButtons() {
  document.addEventListener('click', (e) => {
    const target = e.target.closest('[data-nav]');
    if (target) showScreen(target.dataset.nav);
  });
}

let toastTimer = null;

export function toast(message) {
  const el = document.getElementById('toast');
  el.textContent = message;
  el.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => (el.hidden = true), 2500);
}

export async function copyToClipboard(text) {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    return false;
  }
}

/** createElement helper: el('li', {class: 'row'}, child1, 'text', …) */
export function el(tag, attrs = {}, ...children) {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === 'class') node.className = v;
    else if (k.startsWith('on')) node.addEventListener(k.slice(2), v);
    else node.setAttribute(k, v);
  }
  node.append(...children);
  return node;
}
