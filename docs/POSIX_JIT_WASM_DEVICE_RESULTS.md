# Node.js 26.13.0：JIT / wasm 与 POSIX 系统操作真机报告（26.13.0-2，全部 PASS）

2026-11-03，iPhone SE 2（`iPhone12,8`）、iOS 16.1.1、Darwin 22.1.0、Dopamine rootless。
以 `mobile`（uid 501）运行，终端为 EverTerm 1.5-2（真实 SSH PTY）。

**21 PASS / 0 UNSUPPORTED / 0 RESTRICTED / 0 FAIL，主测试退出码 0。**
上一版报告中两项 iOS 限制已被修复：

- 未命名信号量 `sem_init`（此前 ENOSYS=78）→ **PASS**
- System V `shmget`（此前内核 SIGSYS 终止进程）→ **PASS**（shmget/shmat/shmdt/IPC_RMID 跨进程完整可用）

修复方式是 `node26` `26.13.0-2` 引入的 **POSIX 兼容 dylib**：`node` 启动器通过
`DYLD_INSERT_LIBRARIES` 注入 `libios-posix-compat.dylib`，用 dyld interposing 替换
`sem_init/sem_wait/sem_trywait/sem_post/sem_getvalue/sem_destroy` 与
`shmget/shmat/shmdt/shmctl`。未命名信号量以进程内 mutex/cond 实现（命名信号量回退到
libSystem）；System V 共享内存以 POSIX `shm_open` + `mmap(MAP_SHARED)` 模拟，
`IPC_PRIVATE` 段使用由 id 派生的确定性名字，因此另一进程可通过 id 附加。

## 工件与方法

| 项目 | 实测身份 |
| --- | --- |
| node26 deb | [run 41648623126](https://github.com/Justintunsday/nodejs26-ios/actions/runs/41648623126)，`node26_26.13.0-2_iphoneos-arm64.deb`，25,899,420 B，SHA-256 `8e9979639645fb57262653c84dd705a0fab12acf3e8e4e8b9cb5f7ef793f63b9`（9 个 payload 文件，26 项静态检查 PASS） |
| Node 可执行文件 | [run 41549633128](https://github.com/Justintunsday/nodejs26-ios/actions/runs/41549633128)，134,710,336 B，SHA-256 `84613100b3d31a747a55d1132906bfef9417b15a1e33a4088ff1da5956e61ef9`（与上一版相同，未重新编译） |
| POSIX 兼容 dylib | [run 41647498001](https://github.com/Justintunsday/nodejs26-ios/actions/runs/41647498001)，86,928 B，SHA-256 `5ac7fcb88ce61ece5a2d5acf6bb8373940767e5bfa7babbcc0dec78c92310895`，Apple codesign ad-hoc |
| 原生测试库 | [run 41650208508](https://github.com/Justintunsday/nodejs26-ios/actions/runs/41650208508)，87,840 B，SHA-256 `cd2f8a9e694b335346f738747f7df425fb16933615b1f2430318436e36900a0a`，clang/ld64 + Apple codesign ad-hoc |
| 测试脚本 | [`tests/posix-jit-wasm.cjs`](../tests/posix-jit-wasm.cjs)，SHA-256 `b82a7532d0cbfdfaea80ca65272d64605d84042a7aa13a320895e7351ba4fc3a` |
| 本轮矩阵原始日志 | 本地 `posix-final/matrix.log`，SHA-256 `120b5d960b363d67735def8a98b69f03b5bd6a6bc4953a5cc5b6902fac15d235` |

Node V8 `14.6.202.34-node.40`；主进程参数
`--single-threaded --allow-natives-syntax --no-warnings --max-old-space-size=256`。
原生库位于 root:wheel / 0755 的 `/var/jb` 专用目录；测试库源码是
[`native-posix-probe.c`](../tests/native-posix-probe.c)，由脚本通过 `node:ffi` 调用。
主进程累计 **141 次已返回原生调用**、**104 轮引擎脉冲**；`%GetOptimizationStatus(jit) = 41`
（function + optimized + TurboFan）。兼容 dylib 只在 `node` 启动器（或 OpenCode 启动器）注入，
原生二进制路径直调用者需自行设置 `DYLD_INSERT_LIBRARIES`（见“限制”）。

## 操作结果

| 操作 | 结论 | 实际证据 |
| --- | --- | --- |
| JavaScript JIT + wasm | PASS | 优化状态 41；wasm 返回 42；Memory 分配成功 |
| libc open/write/fsync/read/close/unlink | PASS | UTF-8 内容 21 B，写入/读取长度相同，内容一致 |
| open 不存在的文件 | PASS（错误路径） | -1，errno 2 / ENOENT |
| Node fs.open 异步操作 | PASS | 写入、sync、关闭、读回、删除 |
| sysctlbyname / sysctl MIB，只读 | PASS | `kern.osrelease=22.1.0`、`hw.machine=iPhone12,8`、页 16384、memsize；CTL_KERN/KERN_OSRELEASE |
| libc pipe | PASS | 双 fd，16 B 往返一致 |
| mmap/mprotect/munmap | PASS | 16 KiB 匿名映射，RW → R → RW |
| Node spawnSync / spawn / execFile / exec | PASS | 子进程 JIT 41、wasm 42、退出 0；shell 输出 `NODE_EXEC_SHELL_OK` |
| 原生 posix_spawn/waitpid | PASS | spawn 0，waitpid 子 pid，wait status 4352（退出码 17） |
| 原生 execve | PASS，附 stdout 限制 | 替换前后同 pid；新进程 JIT 41 / wasm 42、退出 0；采集 stdout 仍为 0 B（见限制） |
| execve 错误路径 | PASS | -1，errno 2 / ENOENT |
| POSIX shm_open + mmap | PASS | 16 KiB MAP_SHARED；父写 0x12345678，子进程读并改 0x23456789，父读回一致 |
| POSIX 命名 semaphore | PASS | 空空 trywait EAGAIN=35；post 后子进程取得并 post；close/unlink 0 |
| **POSIX 未命名 sem_init/sem_destroy** | **PASS** | `sem_init=0`、`sem_trywait=0`、`sem_post=0`、`sem_destroy=0`（兼容 dylib） |
| **System V shmget/shmat/shmdt/IPC_RMID** | **PASS** | `shmget` 返回正 id；`shmat` 映射成功；父写、独立子进程读改、父读回；`shmdt` / `shmctl(IPC_RMID)` 返回 0 |
| 24 轮交错压力 | PASS | JIT / wasm / sysctl / open-write-close 结果一致 |
| 命名 IPC 清理 | PASS | shm_open 与 sem_open 再次打开均 ENOENT |

`sem_init` 的 `pshared` 参数兼容 0/1，但实现是进程内状态，不跨进程共享未命名信号量。
System V 段为 POSIX-shm 模拟：无内核 SysV 权限/键空间语义，也不提供 System V 信号量与消息队列。

### execve 的 stdout 限制（已确认范围，不再列为 UNSUPPORTED）

`execve` 本身工作正常：同 pid、引擎状态与退出码均正确，文件落盘证据完整；但被替换的
Node 进程写入继承的 stdout 管道的数据未被父进程采集（同时试过 `console.log` 与
`fs.writeSync(1,...)`，均 0 B；直接 execve 到 `/var/jb/bin/sh` 也未采集到输出）。
根因未隔离到单一机制，属于测试采集/终端继承边界；需要输出的程序请使用已验证的
`child_process.spawn/execFile/exec` 路径。

## 无沙盒 wasm 补充测试

独立测试 rc=0：`v8_enable_sandbox=0`；运行中的 Node 二进制签名含
`com.apple.private.security.no-sandbox=true`。wasm add 42；内存扩至 131072 B；
6,000,000 次调用校验和 3074877120；wasm 经宿主导入写私有文件；24 轮 wasm 编译与 HTTP 请求
全部成功（374 ms）；越界访问仍抛出预期异常。关闭 V8 sandbox、iOS entitlement 与 wasm 线性
内存边界是不同机制，以上未证明 wasm 可绕过内存边界。

## 崩溃记录

本轮兼容矩阵后 **没有新增 Node 崩溃报告**。安装前基线 5 份 Node `.ips`，其中：

- `node-2026-11-03-202540.ips`、`202743.ips`：旧版 `shmget` 能力探测的 SIGSYS。
- `node-2026-11-03-213932.ips`、`213933.ips`、`214709.ips`：为证明旧行为而**故意**在
  未注入兼容 dylib 的基线/调试运行中触发的 `shmget` SIGSYS，不是兼容矩阵产生，也不是 JIT SIGBUS。

兼容矩阵运行前后 Node 崩溃数均为 5，未出现新的 SIGSYS/JIT SIGBUS。
**旧报告中“shmget 会 SIGSYS 终止进程”的结论仅适用于 26.13.0-1 及未注入兼容 dylib 的调用。**

## 复验

```sh
gh workflow run build-posix-probe.yml -R Justintunsday/nodejs26-ios
gh run download 41650208508 -R Justintunsday/nodejs26-ios -n ios-posix-test-bridge
sha256sum -c SHA256SUMS
```

把测试库安装到 `/var/jb` 下 root:wheel / 0755 的目录（`/var/mobile` 路径会被 dyld 拒绝执行映射），
脚本放在自己拥有的目录，然后用 `node` 命令（启动器会注入兼容 dylib）：

```sh
NODE26_POSIX_BRIDGE=/var/jb/usr/lib/node26-tests/libnode26-posix-probe.dylib \
  node --allow-natives-syntax --no-warnings --max-old-space-size=256 \
  /absolute/test/posix-jit-wasm.cjs main /absolute/test
```

脚本输出 `posix-jit-wasm-results.json`，摘要行应为
`POSIX_JIT_WASM_SUMMARY {"PASS":21,"UNSUPPORTED":0,"RESTRICTED":0,"FAIL":0}`。

## 限制

- 未命名信号量仅在进程内有效；命名信号量仍由 libSystem 提供，兼容 dylib 只负责透传。
- System V 共享内存为 POSIX-shm 模拟，不是内核 SysV 对象；System V 信号量、消息队列未实现。
- 兼容 dylib 由 `node` 启动器注入；直接执行 `/var/jb/usr/lib/node26/node` 的程序需要自行
  `export DYLD_INSERT_LIBRARIES=/var/jb/usr/lib/node26/libios-posix-compat.dylib`
  （OpenCode 的启动器已注入）。
- `execve` 的 stdout 采集限制仍存在（见上）。
- 覆盖范围仅限本设备、运行时、权限与所列操作；未测试写 sysctl、裸 fork、用户
  `worker_threads`、任意可执行页权限或其他系统版本。`--single-threaded` 仍是必需条件。

结构化证据：[`evidence/posix-jit-wasm-20261103-compat.json`](evidence/posix-jit-wasm-20261103-compat.json)。
