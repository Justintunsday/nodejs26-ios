// Regression for iOS process-wide W^X: wasm code publication must not race
// main-thread JIT execution, even when Node owns a V8 platform worker pool.
const assert = require('node:assert/strict');
const http = require('node:http');

function uleb(value) {
  const bytes = [];
  do { bytes.push((value & 127) | (value >= 128 ? 128 : 0)); value >>>= 7; } while (value);
  return bytes;
}
function section(id, bytes) { return [id, ...uleb(bytes.length), ...bytes]; }
function wasmFunctions(count) {
  const types = [1, 0x60, 0, 1, 0x7f];
  const funcs = [...uleb(count), ...Array(count).fill(0)];
  const exports = [1, 3, 0x66, 0x6f, 0x6f, 0, 0];
  const code = [...uleb(count), ...Array.from({ length: count }, () => [4, 0, 0x41, 42, 0x0b]).flat()];
  return Uint8Array.from([0, 97, 115, 109, 1, 0, 0, 0,
    ...section(1, types), ...section(3, funcs), ...section(7, exports), ...section(10, code)]);
}
function hotLoop(n) { let sum = 0; for (let i = 0; i < n; i++) sum += i; return sum; }

(async () => {
  let requests = 0;
  const server = http.createServer((_req, res) => { requests++; res.end('ok'); });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const url = `http://127.0.0.1:${server.address().port}`;
  try {
    for (let batch = 0; batch < 24; batch++) {
      const responses = Array.from({ length: 8 }, async () => {
        const response = await fetch(url);
        assert.equal(response.status, 200);
        assert.equal(await response.text(), 'ok');
      });
      // Vary the module to avoid merely exercising the wasm native-module cache.
      const instance = new WebAssembly.Instance(new WebAssembly.Module(wasmFunctions(256 + batch)));
      assert.equal(instance.exports.foo(), 42);
      assert.equal(hotLoop(100000), 4999950000);
      await Promise.all(responses);
    }
    assert.equal(requests, 192);
    console.log(`WASM_HTTP_STRESS_OK requests=${requests} modules=24`);
  } finally {
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
