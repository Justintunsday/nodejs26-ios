// Run on the iPhone as: node standalone-smoke.cjs <writable evidence directory>.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const {spawnSync, fork} = require('node:child_process');
const crypto = require('node:crypto');

async function main() {
  assert.equal(process.platform, 'ios');
  assert.equal(process.version, 'v26.13.0');
  assert.ok(process.execArgv.includes('--single-threaded'));
  assert.ok(fs.realpathSync(process.execPath).endsWith('/usr/lib/node26/node'));
  const directory = fs.mkdtempSync(path.join(process.argv[2], 'standalone-'));
  const checks = [];
  const pass = name => { checks.push(name); console.log('PASS ' + name); };
  pass('independent executable, version, platform and required flags');
  const sha = crypto.createHash('sha256').update(fs.readFileSync(process.execPath)).digest('hex');
  assert.equal(sha, '84613100b3d31a747a55d1132906bfef9417b15a1e33a4088ff1da5956e61ef9');
  pass('signed executable bytes preserved');
  let jit = 0;
  for (let i = 0; i < 3000000; i++) jit += i * i % 7;
  assert.equal(jit, 5999999);
  pass('JIT checksum 5999999');
  const module = new WebAssembly.Module(Buffer.from('0061736d010000000105016000017f0302010007070103666f6f00000a06010400412a0b', 'hex'));
  assert.equal(new WebAssembly.Instance(module).exports.foo(), 42);
  assert.equal(new WebAssembly.Memory({initial:1}).buffer.byteLength, 65536);
  pass('WebAssembly function and memory');
  assert.equal([...new Intl.Segmenter('en', {granularity:'word'}).segment('hello world')].filter(x => x.isWordLike).length, 2);
  assert.ok(/\p{L}/u.test('中'));
  pass('ICU, Intl.Segmenter and Unicode properties');
  const ffi = require('node:ffi');
  const {lib, functions} = ffi.dlopen('/usr/lib/libSystem.B.dylib', {
    getpid: {arguments:[], return:'i32'},
    qsort: {arguments:['pointer','u64','u64','pointer'], return:'void'},
  });
  assert.equal(functions.getpid(), process.pid);
  let calls = 0;
  const callback = lib.registerCallback({arguments:['pointer','pointer'], return:'i32'}, () => {
    assert.equal(functions.getpid(), process.pid);
    calls++;
    return 0;
  });
  functions.qsort(new Uint32Array([2,1]), 2n, 4n, callback);
  assert.ok(calls > 0);
  lib.unregisterCallback(callback);
  lib.close();
  pass('node:ffi native call and reentrant callback');
  const sqlite = require('node:sqlite');
  const database = path.join(directory, 'probe.sqlite');
  const db = new sqlite.DatabaseSync(database);
  db.exec('CREATE TABLE probe(value INTEGER); INSERT INTO probe VALUES(42)');
  assert.equal(db.prepare('SELECT value FROM probe').get().value, 42);
  db.close();
  const sqlChild = spawnSync(process.execPath, [...process.execArgv, '-e', 'const{DatabaseSync}=require("node:sqlite");const d=new DatabaseSync(process.argv[1]);console.log(d.prepare("SELECT value FROM probe").get().value);d.close()', database], {encoding:'utf8',timeout:20000});
  assert.equal(sqlChild.status, 0, sqlChild.stderr);
  assert.equal(sqlChild.stdout.trim(), '42');
  pass('native SQLite persistence across processes');
  const esm = spawnSync(process.execPath, [...process.execArgv, '--input-type=module', '-'], {input:'console.log("ESM_STDIN_OK", await Promise.resolve(42), process.platform)',encoding:'utf8',timeout:20000});
  assert.equal(esm.status, 0, esm.stderr);
  assert.equal(esm.stdout.trim(), 'ESM_STDIN_OK 42 ios');
  pass('ES modules and stdin');
  const childFile = path.join(directory, 'fork.cjs');
  fs.writeFileSync(childFile, 'process.send({platform:process.platform,argv:process.execArgv});process.disconnect();');
  await new Promise((resolve, reject) => {
    const child = fork(childFile, [], {stdio:['ignore','ignore','pipe','ipc']});
    let message;
    const timer = setTimeout(() => { child.kill('SIGKILL'); reject(new Error('fork timed out')); }, 20000);
    child.on('message', data => message = data);
    child.on('error', error => { clearTimeout(timer); reject(error); });
    child.on('exit', code => {
      clearTimeout(timer);
      try { assert.equal(code, 0); assert.equal(message.platform, 'ios'); assert.ok(message.argv.includes('--single-threaded')); resolve(); }
      catch (error) { reject(error); }
    });
  });
  pass('fork inherits required runtime flag');
  const server = http.createServer((req,res) => res.end('NODE26_HTTP_OK'));
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  try {
    const response = await fetch('http://127.0.0.1:' + server.address().port, {signal:AbortSignal.timeout(10000)});
    assert.equal(response.status, 200);
    assert.equal(await response.text(), 'NODE26_HTTP_OK');
  } finally { await new Promise(resolve => server.close(resolve)); }
  pass('HTTP fetch and wasm-backed parser');
  const https = await fetch('https://example.com', {signal:AbortSignal.timeout(20000)});
  assert.equal(https.status, 200);
  await https.arrayBuffer();
  pass('HTTPS fetch status 200');
  const report = {status:'PASS', checks, executable:process.execPath, execArgv:process.execArgv, sha256:sha, jit, callbackCalls:calls, directory};
  fs.writeFileSync(path.join(directory, 'report.json'), JSON.stringify(report,null,2)+'\n');
  console.log('STANDALONE_NODE26_PASS ' + JSON.stringify(report));
}
main().catch(error => { console.error(error); process.exitCode = 1; });
