# Node.js 26.13.0：JIT / wasm 与系统操作真机测试报告

2026-11-03，iPhone SE 2（`iPhone12,8`）、iOS 16.1.1、Darwin 22.1.0、Dopamine rootless。
以 `mobile`（uid 501）运行，主测试时间 **2026-11-03T12:27:40.788Z — 2026-11-03T12:27:42.472Z**。

**19 PASS / 2 UNSUPPORTED / 0 RESTRICTED / 0 FAIL，主测试退出码 0。**
文件、只读系统查询、进程创建/替换、POSIX 共享内存和命名信号量可与 JIT/wasm 共用。
未命名信号量 `sem_init` 返回 ENOSYS；System V `shmget` 触发 SIGSYS。
后者会终止调用进程，不能按普通返回错误处理。

## 工件与方法

| 项目 | 实测身份 |
| --- | --- |
| Node 运行时 | [run 41549633128](https://github.com/Justintunsday/nodejs26-ios/actions/runs/41549633128)，134,710,336 B |
| Node SHA-256 | `84613100b3d31a747a55d1132906bfef9417b15a1e33a4088ff1da5956e61ef9` |
| 独立 deb | [run 41620234785](https://github.com/Justintunsday/nodejs26-ios/actions/runs/41620234785)，`node26` `26.13.0-1`，作者 `nodejs`，命令 `node` |
| deb SHA-256 | `c6cda114912707b5c229178449e0cc0a641fa7165c270a8dd81456196fed9e51` |
| V8 | `14.6.202.34-node.40` |
| 主进程参数 | `--single-threaded --allow-natives-syntax --no-warnings --max-old-space-size=256` |
| 原生测试库 | [run 41634657973](https://github.com/Justintunsday/nodejs26-ios/actions/runs/41634657973)，87,840 B，clang/ld64 + Apple codesign ad-hoc |
| 测试库 SHA-256 | `cd2f8a9e694b335346f738747f7df425fb16933615b1f2430318436e36900a0a` |
| 测试脚本 SHA-256 | `b82a7532d0cbfdfaea80ca65272d64605d84042a7aa13a320895e7351ba4fc3a` |

原生库源码是 [`native-posix-probe.c`](../tests/native-posix-probe.c)，由
[`posix-jit-wasm.cjs`](../tests/posix-jit-wasm.cjs) 通过 `node:ffi` 调用。
`open`、`shm_open` 和 `sem_open` 的可变参数留在 C 中，避免误用 Apple arm64 的可变参数 ABI。
errno 在 C 调用后立即保存，成功与失败的实际返回值均保存在
[结构化证据](evidence/posix-jit-wasm-20261103.json)。
接口依据为 [Node FFI 文档](https://nodejs.org/docs/latest-v26.x/api/ffi.html) 与 Apple
[shm_open](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/shm_open.2.html)、
[sem_open](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/sem_open.2.html)、
[sysctl](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/sysctlbyname.3.html) 接口说明；是否可用以本次设备输出为准。

每项操作前后执行已优化的 JavaScript 函数、wasm 函数与内存分配，期间重新编译 wasm 模块。
主进程累计 **104 轮引擎检查、至少 2,080,000 次 JIT 函数调用、138 次已返回的原生调用**。
异步 spawn 等待期间也继续运行引擎检查。全过程保留 `--single-threaded`，没有使用 `--jitless`。
`%GetOptimizationStatus(jit) = 41 = 1 + 8 + 32`，对应 function、optimized、TurboFan；
位定义按 [Node v26.13.0 内的 V8 源码](https://github.com/nodejs/node/blob/v26.13.0/deps/v8/src/runtime/runtime.h#L1052-L1058) 判定。

## 操作结果

| 操作 | 结论 | 实际证据 |
| --- | --- | --- |
| JavaScript JIT + wasm | PASS | 优化状态 41；wasm 返回 42；Memory 分配成功 |
| libc open/write/fsync/read/close/unlink | PASS | UTF-8 内容 21 B，写入/读取长度相同，内容一致，关闭与删除返回 0 |
| open 不存在的文件 | PASS（错误路径） | 返回 -1，errno 2 / ENOENT |
| Node fs.open 异步操作 | PASS | 独立文件写入、sync、关闭、读回及删除 |
| sysctlbyname，只读 | PASS | `kern.osrelease=22.1.0`、`hw.machine=iPhone12,8`、page size 16384、memsize 3103588352 |
| sysctl MIB，只读 | PASS | `CTL_KERN/KERN_OSRELEASE` 返回 0 与 `22.1.0` |
| libc pipe | PASS | 双 fd，16 B 往返一致，两个 close 返回 0 |
| mmap/mprotect/munmap | PASS | 16 KiB 匿名映射，RW → R → RW，读写值正确，解除映射返回 0 |
| Node spawnSync | PASS | 子进程 JIT 状态 41、wasm 42、退出 0 |
| Node spawn（异步） | PASS | 父进程交错执行引擎检查；子进程退出 0 |
| Node execFile | PASS | Node 子进程 JIT/wasm 成功、退出 0 |
| Node exec（shell） | PASS | `/var/jb/bin/sh` 输出 `NODE_EXEC_SHELL_OK` |
| 原生 posix_spawn/waitpid | PASS | spawn 返回 0，waitpid 返回子 pid；原始 wait status 4352，即预期退出码 17 |
| 原生 execve | PASS，附 stdout 限制 | pid 68021 替换前后相同；新 Node 进程 JIT 状态 41 / wasm 42、退出 0；采集 stdout 为 0 B |
| execve 不存在的文件 | PASS（错误路径） | 返回 -1，errno 2 / ENOENT |
| POSIX shm_open + mmap | PASS | 16 KiB MAP_SHARED；父写 0x12345678，独立子进程读到并改为 0x23456789，父读回相同 |
| POSIX 命名 semaphore | PASS | 空 sem_trywait 返回 -1 / EAGAIN=35；post 后子进程取得并 post，父进程再取得；close/unlink 返回 0 |
| POSIX 未命名 sem_init | **UNSUPPORTED** | 返回 -1，errno 78 / ENOSYS；没有对未初始化对象继续调用 sem_destroy |
| System V shmget | **UNSUPPORTED / SIGSYS** | 隔离子进程 pid 68024 在 shmget 处收到 SIGSYS；没有返回值或 errno；后续 shmat/shmdt/IPC_RMID 未执行 |
| 24 轮交错压力 | PASS | JIT / wasm / sysctl / open-write-close 连续执行，结果一致 |
| 命名 IPC 清理 | PASS | shm_open 与 sem_open 再次打开均得到 ENOENT，未保留本轮命名资源 |

原生 execve 的通过依据是替换前后落盘记录中的相同 pid 与重新执行的引擎结果。
它没有保留本测试采集到的 stdout 输出；本次没有确定原因，不能宣称任意 fd 都能自动跨 exec 保留。
需要采集输出的程序可使用本次已验证的 `child_process.spawn/execFile/exec` 路径。

## 无沙盒 wasm 补充测试

独立测试于 12:08:05 UTC 执行，退出码 0：`v8_enable_sandbox=0`；通过 `ldid -e`
读取正在运行的 Node 二进制签名，含 `com.apple.private.security.no-sandbox=true`。
wasm add 返回 42；内存扩为 131072 B；6,000,000 次 wasm 调用校验和 3074877120；
wasm 经宿主导入写入私有测试文件；24 轮 wasm 编译与 HTTP 请求全部成功，耗时 374 ms。
wasm 越界访问仍抛出预期异常，内存上限仍有效。关闭 V8 sandbox、iOS entitlement 与
wasm 线性内存边界是不同的机制，以上结果没有证明 wasm 可以绕过内存边界。

## 动态库、异常与崩溃记录

初次将同一 SHA 的测试 dylib 放在 mobile 所有的 `/var/mobile/Documents/...` 下，dlopen
返回 `file system sandbox blocked mmap()`，测试退出 1，尚未执行系统操作矩阵。
改为 root:wheel / 0755 安装在 `/var/jb/usr/lib/node26-tests/run41634657973/` 后可加载和执行。
这表明 `no-sandbox` entitlement 不能据此被解释为任何路径的可执行映射都可用。

第一次完整探测直接调用 System V shmget，主进程被 SIGSYS 终止，外层 timeout 返回 140；
随后把该能力探测放到独立子进程，保留 SIGSYS 证据并让主报告正常完成。
测试脚本还纠正了旧 V8 优化位的误判，以及对 execve 后 stdout 必须含 JSON 的错误假设。
最终 19/2/0 的统计来自修正后真正执行的矩阵，不是改写首次失败日志。

最终 CrashReporter 基线 **7 → 12**：

- `node-2026-11-03-202540.ips`，pid 67223，SIGSYS，栈顶 `libsystem_kernel.dylib!shmget` → `probe_shmget`。
- `node-2026-11-03-202743.ips`，隔离子进程 pid 68024，相同 SIGSYS / shmget 栈。
- `timeout-2026-11-03-202539.ips`，pid 67222，SIGSYS，栈为 `raise` → timeout main。
- 两份 Jetsam（20:16:45、20:29:06 +0800）的终止对象均为 `accessoryupdaterd` / per-process-limit；没有 Node 终止条目。

本轮没有观察到新的 JIT SIGBUS。不能写成“没有 Node 崩溃”：上面两份 SIGSYS 确实存在。
测试完成后，专用 mock、测试子进程和 rootless 测试库已清理；原有两个用户服务、两个 TUI、两个 Node REPL 保留。
`dpkg --verify node26 opencode` 返回 0。设备原始日志保存在本地 `device/artifacts/mobile-tui-evidence/`；
仓库结构化证据只收录必要字段和原始文件 SHA，省略 CrashReporter 标识符。

## 复验

测试库按手动工作流构建，无须重新编译 Node：

```sh
gh workflow run build-posix-probe.yml -R Justintunsday/nodejs26-ios
gh run download 41634657973 -R Justintunsday/nodejs26-ios -n ios-posix-test-bridge
sha256sum -c SHA256SUMS
```

将库以 root:wheel / 0755 放在 `/var/jb` 的专用测试目录，脚本放在自己拥有的可写目录。
在手机执行，按实际路径替换下列两个绝对路径：

```sh
NODE26_POSIX_BRIDGE=/var/jb/usr/lib/node26-tests/libnode26-posix-probe.dylib \
  node --allow-natives-syntax --no-warnings --max-old-space-size=256 \
  /absolute/test/posix-jit-wasm.cjs main /absolute/test
```

脚本会在指定目录输出 `posix-jit-wasm-results.json`。System V 探测在该 iOS 上会产生 SIGSYS 子进程报告。
覆盖范围仅为上述设备、运行时、权限和所执行的操作；没有测试写 sysctl、裸 fork、用户 worker_threads、
System V semaphore、任意可执行页权限或其他系统版本。`--single-threaded` 仍是必需条件。
