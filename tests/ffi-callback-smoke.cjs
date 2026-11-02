// Run on the iPhone with the built runtime and --single-threaded.
// Regression: the old runtime executes its malloc-allocated callback and SIGBUSes.
const assert = require('node:assert/strict');
const ffi = require('node:ffi');
const {lib, functions} = ffi.dlopen('/usr/lib/libSystem.B.dylib', {
  qsort: {arguments:['pointer','u64','u64','pointer'],return:'void'},
  getpid: {arguments:[],return:'i32'},
});
let count = 0;
const callback = lib.registerCallback({arguments:['pointer','pointer'],return:'i32'}, () => {
  assert.equal(functions.getpid(), process.pid);
  count++;
  return 0;
});
const values = new Uint32Array([2,1]);
functions.qsort(values, 2n, 4n, callback);
assert.ok(count > 0);
lib.unregisterCallback(callback);
lib.close();
console.log('FFI_CALLBACK_OK calls=' + count);
