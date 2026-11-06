// The theme toggle, and Firebase Analytics for page views and download clicks.
import { firebaseConfig } from './config.js';

const SDK = 'https://www.gstatic.com/firebasejs/12.19.0';
const root = document.documentElement;

// The theme follows Windows until the toggle picks one.
document.querySelector('[data-theme-toggle]')?.addEventListener('click', () => {
  const dark = root.dataset.theme
    ? root.dataset.theme === 'dark'
    : matchMedia('(prefers-color-scheme: dark)').matches;
  root.dataset.theme = dark ? 'light' : 'dark';
  try {
    localStorage.setItem('theme', root.dataset.theme);
  } catch {}
});

// Mac visitors get the Mac download first and from the header button. iPads
// also say they're Macs, but have touch screens, and can't run either app.
const platform = navigator.userAgentData?.platform ?? navigator.platform ?? '';
if (/mac/i.test(platform) && navigator.maxTouchPoints < 2) {
  for (const group of document.querySelectorAll('[data-downloads]')) {
    const mac = group.querySelector('[data-os="mac"]');
    const windows = group.querySelector('[data-os="windows"]');
    if (!mac || !windows) continue;
    group.prepend(mac);
    mac.classList.add('btn-primary');
    windows.classList.remove('btn-primary');
  }
  const header = document.querySelector('[data-mac-href]');
  if (header) header.href = header.dataset.macHref;
}

// The Hosting site serving this page: "artcraftappsmanager" for
// artcraftappsmanager.web.app, its .firebaseapp.com twin and its preview
// channels (artcraftappsmanager--<channel>.web.app). Any other address, such
// as a custom domain, is reported as is.
const host = location.hostname;
const site = /\.(web\.app|firebaseapp\.com)$/.test(host) ? host.split('.')[0].split('--')[0] : host;
const local = !host || /^(localhost|127\.0\.0\.1|\[::1\])$/.test(host);

// Clicks are queued until Analytics has loaded, so early clicks still count.
const queue = [];
let send = (name, params) => queue.push([name, params]);

document.addEventListener('click', (event) => {
  const link = event.target.closest('a[data-download]');
  if (!link) return;
  send('download_click', {
    placement: link.dataset.download,
    version: root.dataset.version,
    file_name: link.pathname.split('/').pop(),
  });
});

startAnalytics().catch((error) => {
  send = () => {};
  console.warn('Analytics is off:', error);
});

async function startAnalytics() {
  if (local) {
    // A local preview: log instead of polluting the real numbers.
    send = (name, params) => console.info('[analytics]', name, { site, ...params });
  } else {
    const [{ initializeApp }, { initializeAnalytics, isSupported, logEvent }] = await Promise.all([
      import(`${SDK}/firebase-app.js`),
      import(`${SDK}/firebase-analytics.js`),
    ]);
    if (!(await isSupported())) throw new Error('not supported in this browser');
    // The config tags the automatic page view with the site; the events
    // logged here carry it themselves.
    const analytics = initializeAnalytics(initializeApp(firebaseConfig), { config: { site } });
    send = (name, params) => logEvent(analytics, name, { site, ...params });
  }
  for (const [name, params] of queue.splice(0)) send(name, params);
}
