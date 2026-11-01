const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
test('HTML local scripts exist and share a valid global scope', () => {
    const html = fs.readFileSync(path.join(__dirname, 'index.html'), 'utf8');
    const scripts = [...html.matchAll(/<script src="([^":]+\.js)"><\/script>/g)].map(m => m[1]);
    assert.equal(scripts.length, 8);
    new vm.Script(scripts.map(p => fs.readFileSync(path.join(__dirname, p), 'utf8')).join('\n'));
});
test('service worker can precache every declared local asset', async () => {
    const handlers = {};
    let cached;
    const self = { location: { origin: 'https://example.com' }, addEventListener: (name, fn) => handlers[name] = fn };
    vm.runInNewContext(fs.readFileSync(path.join(__dirname, 'service-worker.js'), 'utf8'), {
        self, URL, console, caches: { open: async () => ({ addAll: async urls => { cached = urls; } }) }
    });
    let installed;
    handlers.install({ waitUntil: p => installed = p }); await installed;
    for (const asset of cached) assert.ok(fs.existsSync(path.join(__dirname, asset === '/' ? 'index.html' : asset)), asset);
    for (const request of [{ method: 'POST', url: 'https://example.com/api' }, { method: 'GET', url: 'https://provider.example/api' }]) {
        handlers.fetch({ request, respondWith: () => assert.fail('API request intercepted') });
    }
});
