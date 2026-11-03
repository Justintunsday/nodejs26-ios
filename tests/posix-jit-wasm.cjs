// Device-only: node --allow-natives-syntax posix-jit-wasm.cjs main <owned directory>
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const cp = require('node:child_process');
const {promisify} = require('node:util');
const ffi = require('node:ffi');
const mode = process.argv[2] || 'main';
const directory = process.argv[3];
if (!directory || !fs.statSync(directory).isDirectory()) throw new Error('Owned evidence directory required');
const bridge = process.env.NODE26_POSIX_BRIDGE || path.join(directory,'libnode26-posix-probe.dylib');
const definitions = {
  probe_errno:[[],'i32'], probe_strerror:[['i32'],'pointer'], probe_constant:[['string'],'i32'],
  probe_open:[['string','i32','u32'],'i32'], probe_close:[['i32'],'i32'],
  probe_write:[['i32','pointer','u64'],'i64'], probe_read:[['i32','pointer','u64'],'i64'],
  probe_fsync:[['i32'],'i32'], probe_ftruncate:[['i32','i64'],'i32'], probe_unlink:[['string'],'i32'],
  probe_pipe:[['pointer'],'i32'], probe_sysctlbyname:[['string','pointer','pointer'],'i32'],
  probe_sysctl:[['pointer','u32','pointer','pointer'],'i32'],
  probe_mmap:[['i32','u64','i32','i32'],'pointer'], probe_pointer_failed:[['pointer'],'i32'],
  probe_mprotect:[['pointer','u64','i32'],'i32'], probe_munmap:[['pointer','u64'],'i32'],
  probe_store:[['pointer','u32'],'void'], probe_load:[['pointer'],'u32'],
  probe_shm_open:[['string','i32','u32'],'i32'], probe_shm_unlink:[['string'],'i32'],
  probe_sem_open:[['string','i32','u32','u32'],'pointer'], probe_sem_failed:[['pointer'],'i32'],
  probe_sem_close:[['pointer'],'i32'], probe_sem_unlink:[['string'],'i32'],
  probe_sem_post:[['pointer'],'i32'], probe_sem_trywait:[['pointer'],'i32'],
  probe_sem_init:[['pointer','u32'],'i32'], probe_sem_destroy:[['pointer'],'i32'], probe_sem_size:[[],'i32'],
  probe_shmget:[['u64'],'i32'], probe_shmat:[['i32'],'pointer'], probe_shmdt:[['pointer'],'i32'], probe_shm_rmid:[['i32'],'i32'],
  probe_posix_spawn:[['string','string','string','string','pointer'],'i32'], probe_waitpid:[['i32','pointer'],'i32'],
  probe_execve:[['string','string','string','string'],'i32'],
};
const {lib,functions:f} = ffi.dlopen(bridge,Object.fromEntries(Object.entries(definitions).map(([name,[args,result]])=>[name,{arguments:args,return:result}])));
const C = name => f.probe_constant(name);
const traces = [];
const json = value => JSON.stringify(value,(_key,item)=>typeof item==='bigint'?item.toString():item);
const errnoNames = Object.entries(os.constants.errno);
const errorText = value => ffi.toString(f.probe_strerror(value));
function native(name,...args) {
  const result=f['probe_'+name](...args);
  const errno=f.probe_errno();
  traces.push({function:name,result:typeof result==='bigint'?result.toString():result,errno,errnoName:errnoNames.find(([,n])=>n===errno)?.[0]||'',error:errno?errorText(errno):''});
  return result;
}
class CapabilityError extends Error {
  constructor(operation,errno) {super(operation+': '+errno+' '+errorText(errno));this.errno=errno;}
}
class NativeSignalError extends Error {
  constructor(signal,detail) {super('System V probe terminated by '+signal);this.detail=detail;}
}
function success(result,operation,optional=false) {
  if (result===-1 || result===-1n) {
    const errno=traces.at(-1).errno;
    if(optional && [C('ENOSYS'),os.constants.errno.ENOTSUP,C('EPERM'),C('EACCES')].includes(errno)) throw new CapabilityError(operation,errno);
    assert.fail(operation+': '+json(traces.at(-1)));
  }
  return result;
}
const wasmBytes=Buffer.from('0061736d010000000105016000017f0302010007070103666f6f00000a06010400412a0b','hex');
const wasm=new WebAssembly.Instance(new WebAssembly.Module(wasmBytes));
function jit(value) {return (value*3+7)|0;}
const prepare=Function('fn','%PrepareFunctionForOptimization(fn)');
const optimize=Function('fn','%OptimizeFunctionOnNextCall(fn)');
const optimizationStatus=Function('fn','return %GetOptimizationStatus(fn)');
prepare(jit);
for(let i=0;i<10000;i++) jit(i);
optimize(jit); jit(42);
let pulses=0;
function pulse() {
  assert.equal(jit(42),133);
  let checksum=0;
  for(let i=0;i<20000;i++) checksum+=jit(i);
  assert.equal(checksum,600110000);
  assert.equal(wasm.exports.foo(),42);
  const memory=new WebAssembly.Memory({initial:1,maximum:2});
  new Uint32Array(memory.buffer)[0]=42;
  assert.equal(new Uint32Array(memory.buffer)[0],42);
  if(++pulses%5===0) assert.equal(new WebAssembly.Instance(new WebAssembly.Module(wasmBytes)).exports.foo(),42);
}
function engine() {return {jitStatus:optimizationStatus(jit),wasm:wasm.exports.foo(),pulses};}
const script=__filename;
const childArgs=childMode=>['--single-threaded','--allow-natives-syntax','--no-warnings','--max-old-space-size=256',script,childMode,directory];
function child(childMode) {
  const result=cp.spawnSync(process.execPath,childArgs(childMode),{encoding:'utf8',timeout:20000,maxBuffer:1024*1024});
  assert.equal(result.error,undefined,result.error?.message);
  assert.equal(result.signal,null,result.stderr);
  assert.equal(result.status,0,result.stderr+'\n'+result.stdout);
  return JSON.parse(result.stdout.trim());
}
function sysctl(name) {
  const data=Buffer.alloc(4096),size=Buffer.alloc(8);size.writeBigUInt64LE(4096n);
  success(native('sysctlbyname',name,data,size),'sysctlbyname '+name);
  return data.subarray(0,Number(size.readBigUInt64LE()));
}
function mapped(fd,flags) {
  const pointer=native('mmap',fd,16384n,C('PROT_READ')|C('PROT_WRITE'),flags);
  assert.equal(f.probe_pointer_failed(pointer),0,json(traces.at(-1)));
  return pointer;
}
async function run() {
  assert.equal(process.platform,'ios');assert.equal(process.version,'v26.13.0');
  assert.ok(process.execArgv.includes('--single-threaded'));
  assert.ok(!process.execArgv.includes('--jitless'));
  pulse();
  if(mode==='node-child') {console.log(json({pid:process.pid,version:process.version,flags:process.execArgv,engine:engine(),marker:'NODE_CHILD_OK'}));return;}
  if(mode==='native-child') {fs.writeFileSync(path.join(directory,'native-child.json'),json({pid:process.pid,flags:process.execArgv,engine:engine()}));console.log('NATIVE_CHILD_JIT_WASM_OK pid='+process.pid);process.exitCode=17;return;}
  if(mode==='exec-pre') {
    fs.writeFileSync(path.join(directory,'exec-before.json'),json({pid:process.pid,engine:engine()}));
    const result=native('execve',process.execPath,script,'exec-post',directory);
    throw new Error('execve unexpectedly returned '+result+' '+json(traces.at(-1)));
  }
  if(mode==='exec-post') {fs.writeFileSync(path.join(directory,'exec-after.json'),json({pid:process.pid,flags:process.execArgv,engine:engine()}));console.log(json({marker:'NATIVE_EXECVE_OK',pid:process.pid,engine:engine()}));return;}
  if(mode==='shm-child') {
    const name=fs.readFileSync(path.join(directory,'shm-name.txt'),'utf8');
    const fd=success(native('shm_open',name,C('O_RDWR'),0),'child shm_open');
    let pointer;
    try {pointer=mapped(fd,C('MAP_SHARED'));assert.equal(f.probe_load(pointer),0x12345678);f.probe_store(pointer,0x23456789);pulse();}
    finally {if(pointer)success(native('munmap',pointer,16384n),'child munmap');success(native('close',fd),'child close');}
    console.log(json({marker:'SHM_CHILD_OK',engine:engine()}));return;
  }
  if(mode==='sem-child') {
    const name=fs.readFileSync(path.join(directory,'sem-name.txt'),'utf8');
    const semaphore=native('sem_open',name,0,0,0);assert.equal(f.probe_sem_failed(semaphore),0,json(traces.at(-1)));
    try {success(native('sem_trywait',semaphore),'child sem_trywait');pulse();success(native('sem_post',semaphore),'child sem_post');}
    finally {success(native('sem_close',semaphore),'child sem_close');}
    console.log(json({marker:'SEM_CHILD_OK',engine:engine()}));return;
  }
  if(mode==='sysv-child') {
    const id=Number(fs.readFileSync(path.join(directory,'sysv-id.txt'),'utf8'));
    const pointer=native('shmat',id);assert.equal(f.probe_pointer_failed(pointer),0,json(traces.at(-1)));
    try {assert.equal(f.probe_load(pointer),0x12345678);f.probe_store(pointer,0x23456789);pulse();}
    finally {success(native('shmdt',pointer),'child shmdt');}
    console.log(json({marker:'SYSV_CHILD_OK',engine:engine()}));return;
  }
  if(mode==='sysv-probe') {
    fs.writeFileSync(path.join(directory,'sysv-attempt.json'),json({pid:process.pid,phase:'before shmget',engine:engine()}));
    const id=native('shmget',16384n);
    if(id<0) {console.log(json({supported:false,calls:traces}));return;}
    let pointer;
    try {pointer=native('shmat',id);assert.equal(f.probe_pointer_failed(pointer),0,json(traces.at(-1)));f.probe_store(pointer,0x12345678);fs.writeFileSync(path.join(directory,'sysv-id.txt'),String(id));const result=child('sysv-child');assert.equal(f.probe_load(pointer),0x23456789);console.log(json({supported:true,id,child:result}));}
    finally {if(pointer&&!f.probe_pointer_failed(pointer))success(native('shmdt',pointer),'shmdt');success(native('shm_rmid',id),'shmctl IPC_RMID');}
    return;
  }
  assert.equal(mode,'main');
  const startedAt=new Date().toISOString(),rows=[];
  async function test(name,fn) {
    const start=Date.now(),from=traces.length;
    let status='PASS',detail,error;
    pulse();
    try {detail=await fn();} catch(cause) {
      error=cause.stack;
      status=cause instanceof CapabilityError ? ([C('EPERM'),C('EACCES')].includes(cause.errno)?'RESTRICTED':'UNSUPPORTED'):cause instanceof NativeSignalError?'UNSUPPORTED':'FAIL';
      if(cause.detail) detail=cause.detail;
    }
    pulse();
    const row={name,status,elapsedMs:Date.now()-start,engine:engine(),detail,error,calls:traces.slice(from)};
    rows.push(row);console.log('RESULT '+json(row));
  }
  // Node 26.13.0 / V8 14.6 runtime.h: optimized=1<<3, TurboFan=1<<5.
  await test('JIT optimization and wasm memory',()=>{assert.ok(optimizationStatus(jit)&8,'function did not reach V8 optimized status');assert.ok(optimizationStatus(jit)&32,'function did not reach TurboFan');return engine();});
  await test('libc open/write/fsync/read/close/unlink',()=>{
    const filename=path.join(directory,'native-open.txt'),data=Buffer.from('JIT_WASM_OPEN_中文\n');
    let fd=success(native('open',filename,C('O_RDWR')|C('O_CREAT')|C('O_EXCL'),0o600),'open');
    try {assert.equal(native('write',fd,data,BigInt(data.length)),BigInt(data.length));success(native('fsync',fd),'fsync');}
    finally {success(native('close',fd),'close');}
    fd=success(native('open',filename,C('O_RDWR'),0),'reopen');
    const output=Buffer.alloc(data.length);
    try {assert.equal(native('read',fd,output,BigInt(output.length)),BigInt(data.length));assert.deepEqual(output,data);}
    finally {success(native('close',fd),'close');success(native('unlink',filename),'unlink');}
    return {bytes:data.length,utf8:output.toString()};
  });
  await test('libc open error path ENOENT',()=>{
    assert.equal(native('open',path.join(directory,'does-not-exist'),C('O_RDWR'),0),-1);
    assert.equal(traces.at(-1).errno,C('ENOENT'));return traces.at(-1);
  });
  await test('Node fs.open asynchronous file I/O',async()=>{
    const filename=path.join(directory,'node-open.txt'),handle=await fs.promises.open(filename,'wx',0o600);
    try {await handle.writeFile('NODE_FS_OPEN_OK\n');await handle.sync();} finally {await handle.close();}
    assert.equal(await fs.promises.readFile(filename,'utf8'),'NODE_FS_OPEN_OK\n');await fs.promises.unlink(filename);
    return {marker:'NODE_FS_OPEN_OK'};
  });
  await test('sysctlbyname read-only values',()=>{
    const values={};
    for(const name of ['kern.osrelease','hw.machine','hw.pagesize','hw.memsize']) {
      const data=sysctl(name);
      values[name]=name==='hw.memsize'?data.readBigUInt64LE().toString():name==='hw.pagesize'?data.readUInt32LE():data.toString().replace(/\0.*$/s,'');
    }
    assert.ok(values['hw.pagesize']>0);return values;
  });
  await test('sysctl MIB read-only kern.osrelease',()=>{
    const mib=new Int32Array([C('CTL_KERN'),C('KERN_OSRELEASE')]),data=Buffer.alloc(256),size=Buffer.alloc(8);size.writeBigUInt64LE(256n);
    assert.equal(native('sysctl',mib,2,data,size),0);
    const value=data.subarray(0,Number(size.readBigUInt64LE())).toString().replace(/\0.*$/s,'');assert.ok(value.length>0);return {value};
  });
  await test('libc pipe round trip',()=>{
    const descriptors=new Int32Array(2);success(native('pipe',descriptors),'pipe');
    const input=Buffer.from('PIPE_JIT_WASM_OK'),output=Buffer.alloc(input.length);
    try {assert.equal(native('write',descriptors[1],input,BigInt(input.length)),BigInt(input.length));assert.equal(native('read',descriptors[0],output,BigInt(output.length)),BigInt(input.length));assert.deepEqual(output,input);}
    finally {success(native('close',descriptors[0]),'close pipe');success(native('close',descriptors[1]),'close pipe');}
    return {bytes:output.length};
  });
  await test('anonymous mmap/mprotect/munmap',()=>{
    const pointer=mapped(-1,C('MAP_PRIVATE')|C('MAP_ANON'));
    try {f.probe_store(pointer,0x12345678);assert.equal(f.probe_load(pointer),0x12345678);success(native('mprotect',pointer,16384n,C('PROT_READ')),'mprotect READ');assert.equal(f.probe_load(pointer),0x12345678);success(native('mprotect',pointer,16384n,C('PROT_READ')|C('PROT_WRITE')),'mprotect RW');f.probe_store(pointer,42);assert.equal(f.probe_load(pointer),42);}
    finally {success(native('munmap',pointer,16384n),'munmap');}
    return {bytes:16384,protection:'RW -> R -> RW'};
  });
  await test('Node spawnSync child with JIT and wasm',()=>child('node-child'));
  await test('Node spawn asynchronous child with JIT and wasm',()=>new Promise((resolve,reject)=>{
    const processChild=cp.spawn(process.execPath,childArgs('node-child'),{stdio:['ignore','pipe','pipe']});let stdout='',stderr='';
    const timer=setTimeout(()=>{processChild.kill('SIGKILL');reject(new Error('spawn timeout'));},20000);
    const activity=setInterval(pulse,10);
    processChild.stdout.on('data',data=>stdout+=data);processChild.stderr.on('data',data=>stderr+=data);
    processChild.on('error',reject);processChild.on('close',(code,signal)=>{clearTimeout(timer);clearInterval(activity);try {assert.equal(code,0,stderr);assert.equal(signal,null);resolve(JSON.parse(stdout.trim()));} catch(error) {reject(error);}});
  }));
  await test('Node execFile child with JIT and wasm',async()=>{
    const result=await promisify(cp.execFile)(process.execPath,childArgs('node-child'),{encoding:'utf8',timeout:20000});return JSON.parse(result.stdout.trim());
  });
  await test('Node exec shell command',async()=>{
    const result=await promisify(cp.exec)("printf 'NODE_EXEC_SHELL_OK'",{shell:'/var/jb/bin/sh',encoding:'utf8',timeout:20000});assert.equal(result.stdout,'NODE_EXEC_SHELL_OK');return {stdout:result.stdout};
  });
  await test('native posix_spawn and waitpid',()=>{
    const pid=new Int32Array(1),status=new Int32Array(1);
    assert.equal(native('posix_spawn',process.execPath,script,'native-child',directory,pid),0);
    assert.equal(native('waitpid',pid[0],status),pid[0]);assert.equal(status[0],17<<8);
    const record=JSON.parse(fs.readFileSync(path.join(directory,'native-child.json'),'utf8'));assert.equal(record.pid,pid[0]);assert.equal(record.engine.wasm,42);return {pid:pid[0],waitStatus:status[0],exitCode:17,child:record};
  });
  await test('native execve replaces a JIT/wasm child',()=>{
    const result=cp.spawnSync(process.execPath,childArgs('exec-pre'),{encoding:'utf8',timeout:20000});
    assert.equal(result.error,undefined);assert.equal(result.status,0,result.stderr);assert.equal(result.signal,null);
    const before=JSON.parse(fs.readFileSync(path.join(directory,'exec-before.json'),'utf8')),after=JSON.parse(fs.readFileSync(path.join(directory,'exec-after.json'),'utf8'));
    assert.equal(before.pid,after.pid);assert.equal(after.engine.wasm,42);assert.ok(after.engine.jitStatus&8);return {samePid:before.pid,before:before.engine,after:after.engine,stdoutBytes:Buffer.byteLength(result.stdout)};
  });
  await test('native execve error path ENOENT',()=>{
    assert.equal(native('execve',path.join(directory,'missing-executable'),script,'node-child',directory),-1);assert.equal(traces.at(-1).errno,C('ENOENT'));return traces.at(-1);
  });
  const sharedName='/n26m'+process.pid,semName='/n26s'+process.pid;
  await test('POSIX shm_open and cross-process shared mapping',()=>{
    const fd=success(native('shm_open',sharedName,C('O_RDWR')|C('O_CREAT')|C('O_EXCL'),0o600),'shm_open',true);let pointer;
    try {success(native('ftruncate',fd,16384n),'shm ftruncate');pointer=mapped(fd,C('MAP_SHARED'));f.probe_store(pointer,0x12345678);fs.writeFileSync(path.join(directory,'shm-name.txt'),sharedName);const result=child('shm-child');assert.equal(f.probe_load(pointer),0x23456789);return {name:sharedName,bytes:16384,child:result};}
    finally {if(pointer)success(native('munmap',pointer,16384n),'shm munmap');success(native('close',fd),'shm close');success(native('shm_unlink',sharedName),'shm unlink');}
  });
  await test('POSIX named semaphore across processes',()=>{
    const semaphore=native('sem_open',semName,C('O_CREAT')|C('O_EXCL'),0o600,0);
    if(f.probe_sem_failed(semaphore)) {const errno=traces.at(-1).errno;if([C('ENOSYS'),C('EPERM'),C('EACCES')].includes(errno))throw new CapabilityError('sem_open',errno);assert.fail(json(traces.at(-1)));}
    try {assert.equal(native('sem_trywait',semaphore),-1);assert.equal(traces.at(-1).errno,C('EAGAIN'));success(native('sem_post',semaphore),'sem_post');fs.writeFileSync(path.join(directory,'sem-name.txt'),semName);const result=child('sem-child');success(native('sem_trywait',semaphore),'sem_trywait after child');return {name:semName,emptyErrno:C('EAGAIN'),child:result};}
    finally {success(native('sem_close',semaphore),'sem_close');success(native('sem_unlink',semName),'sem_unlink');}
  });
  await test('POSIX unnamed sem_init/sem_destroy',()=>{
    const storage=Buffer.alloc(f.probe_sem_size());success(native('sem_init',storage,1),'sem_init',true);
    try {success(native('sem_trywait',storage),'unnamed sem_trywait');success(native('sem_post',storage),'unnamed sem_post');}
    finally {success(native('sem_destroy',storage),'sem_destroy');}
    return {storage:storage.length};
  });
  await test('System V shmget/shmat/shmdt/IPC_RMID',()=>{
    const result=cp.spawnSync(process.execPath,childArgs('sysv-probe'),{encoding:'utf8',timeout:20000});
    assert.equal(result.error,undefined,result.error?.message);
    if(result.signal==='SIGSYS') {
      const attempt=JSON.parse(fs.readFileSync(path.join(directory,'sysv-attempt.json'),'utf8'));
      throw new NativeSignalError(result.signal,{signal:result.signal,status:result.status,attempt,stderr:result.stderr});
    }
    assert.equal(result.status,0,result.stderr);assert.equal(result.signal,null);
    const record=JSON.parse(result.stdout.trim());
    if(!record.supported) throw new CapabilityError('shmget',record.calls.at(-1).errno);
    return record;
  });
  await test('24 rounds interleaved JIT/wasm, sysctl and file open',()=>{
    const filename=path.join(directory,'stress-open.txt');
    for(let round=0;round<24;round++) {pulse();sysctl('kern.osrelease');const fd=success(native('open',filename,C('O_RDWR')|C('O_CREAT')|C('O_TRUNC'),0o600),'stress open');try {const value=Buffer.from(String(wasm.exports.foo()));assert.equal(native('write',fd,value,BigInt(value.length)),BigInt(value.length));} finally {success(native('close',fd),'stress close');}pulse();}
    success(native('unlink',filename),'stress unlink');return {rounds:24,engine:engine()};
  });
  await test('named IPC resources removed',()=>{
    const shared=rows.find(row=>row.name.startsWith('POSIX shm_open'));
    if(shared.status==='PASS') {assert.equal(native('shm_open',sharedName,C('O_RDWR'),0),-1);assert.equal(traces.at(-1).errno,C('ENOENT'));}
    const semaphore=rows.find(row=>row.name.startsWith('POSIX named'));
    if(semaphore.status==='PASS') {const missing=native('sem_open',semName,0,0,0);assert.equal(f.probe_sem_failed(missing),1);assert.equal(traces.at(-1).errno,C('ENOENT'));}
    return {sharedName,semName,remainingNamedResources:0};
  });
  const report={startedAt,finishedAt:new Date().toISOString(),runtime:{version:process.version,platform:process.platform,pid:process.pid,uid:process.getuid(),flags:process.execArgv,executable:process.execPath,sha256:crypto.createHash('sha256').update(fs.readFileSync(process.execPath)).digest('hex'),v8:process.versions.v8,v8_enable_sandbox:process.config.variables.v8_enable_sandbox},bridge:{file:bridge,sha256:crypto.createHash('sha256').update(fs.readFileSync(bridge)).digest('hex')},engine:engine(),summary:Object.fromEntries(['PASS','UNSUPPORTED','RESTRICTED','FAIL'].map(status=>[status,rows.filter(row=>row.status===status).length])),nativeCalls:traces.length,rows};
  fs.writeFileSync(path.join(directory,'posix-jit-wasm-results.json'),json(report)+'\n');
  console.log('POSIX_JIT_WASM_SUMMARY '+json(report.summary)+' calls='+traces.length+' pulses='+pulses);
  process.exitCode=report.summary.FAIL?1:0;
}
run().catch(error=>{console.error(error);process.exitCode=1;}).finally(()=>lib.close());
