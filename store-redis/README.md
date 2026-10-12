# moon-token-store-redis

`TokenStore` 的 Redis 后端：把会话放到 Redis 里，多个进程/多个实例共享同一份登录态。
内存版只在单进程内有效，文件版解决"重启不丢"，**这一版解决"多实例共享"**。

依赖只有两件：`mldong/moon-token-store`（端口与线格式）与 `oboard/redis`（连接与帧）。
`@port.set_clock` 一类的测试注入不用它关心——过期只由传进来的绝对时刻与 `sweep(now)` 决定。

## 键位与物理映射

线格式与键名都由共享内核（`store/port`）给出，本模块不自造字段名：

| 键 | 形状 | 说明 |
|---|---|---|
| `{realm}:T:{token}` | STRING | 会话记录；到期点用 `PEXPIREAT` |
| `{realm}:A:{login_id}` | STRING（整条 `FamilyRecord`） | 反向族索引；**写必须 CAS**，见下 |
| `{realm}:Z` | ZSET（member=token，score=登录时刻） | `list_sessions` 的枚举源 |
| `{realm}:S:` / `R:` / `D:` / `P:` | STRING | 账号态 / refresh 绑定 / 封禁 / 授权快照 |

族写不做"读全块→改→整块覆盖"：那样两台设备并发登录会互相丢成员。这里走 Lua 的
compare-and-set（比对整块旧载荷）＋有界重试，比对不上就重读再改。`{realm}:Z` 与族、
`T:` 之间不做跨命令事务——索引是派生缓存，权威在 `T:`，脏成员由 `sweep` 收。

## 三条与参考实现对齐的硬口径

1. **惰性过期分两档**：会话时效已过但保留宽窗还在时，`get` 照旧交回载荷，让裁决层能报
   `SessionExpired` 而不是塌成 `UnknownToken`；墓碑过窗则读作缺失。加窗只加在
   `TokenConfig::key_expire_at` 那一处（core 传给 store 的就是加过窗的值），适配器不再二次加窗。
2. **`apply` 幂等**：同一个补丁投两次不重复加成员、不重复推版本号；`ForgetTokens` 与
   `RemoveTokens` 的差别只在留不留 `T:` 键；`RefreshLogin` 移回队尾刷 `lt` 但不推版本。
3. **`list_sessions` 的序与游标和内存版逐字同尺**（登录时刻新在前，同刻按 token 字典序倒排）。
   尺子函数在 `mapping_wbtest.mbt` 的 RM1–RM5 里对着一批数据钉住，真机上 RS7 再拿内存版与
   Redis 版比同一批会话给出的页序。

## 服务端版本：支持 Redis 5.0 及以上

本模块只用一套**早在 Redis 2.6/2.8 就存在**的命令：`SET` `GET` `DEL` `EXISTS` `MGET` `PING`
`PTTL` `PEXPIREAT` `EVAL`(Lua 5) `ZADD` `ZREM` `ZRANGE` `HSET` `HGETALL` `SCAN … MATCH … COUNT`。
**实测过的最低版本是 Redis 5.0.4**——正是官网一键包（17 个部署包）实际钉的那一版，也是开发库
192.168.1.160 跑的那一版；实测过的最高版本是 8.0.5。同一批 RS1–RS8 用例在这两台上都是全绿，
所以"支持 5.0+"不是按命令集推断，是跑出来的。低于 5.0 只到 2.8 这一段属于"按命令集应可用、
未实测"，别当承诺引用。

在 5.0.4 上实测**不存在**的服务端命令（库里有对应 typed 方法，调了就 `ERR unknown command`，
响失败不静默）：`GETDEL` `GETEX` `COPY` `HRANDFIELD` `SMISMEMBER` `ZRANGESTORE` `XAUTOCLAIM`
`SINTERCARD` `LMPOP` `ZMPOP` `EXPIRETIME` `GEOSEARCH`。
实测**语法不支持**的 `SET` 选项：`PXAT`、`EXAT`、`KEEPTTL`（三者都是 6.0+；相对 `EX`/`PX` 全版本可用）。
另有一批与版本无关的门槛：`json.mbt` 那套 `JSON.*` 要 **RedisJSON 模块**，不是 Redis 版本问题。

⇒ 维护本模块的纪律：**别为了省事换成 6.x 才有的命令**。要绝对到期点就 `SET` + `PEXPIREAT` 两步；
要原子取删就 `EVAL`。改成 `GETDEL`/`SET … PXAT` 会在 8.x 上一片绿、发到 5.0.4 立刻报红。

## 用之前要知道的四件事（`oboard/redis` 的形状，不是本模块的发明）

- **`get` 走的是原始命令 + 变体匹配**，不用 typed `get`：后者把"键不存在"报成
  `Err("Type mismatch: expected string")`，与真正的错误同码，鉴权路径上不可分辨。
  同理 `get_many` 不用 `to_array()`（它把 nil 元素渲染成字面串 `"null"`）。
- **`get_and_del` 用 Lua 而不是 `GETDEL`**：后者要 Redis 6.2+，而我们部署的是 5.0.4。
- **到期点用 `SET` + `PEXPIREAT` 两步**：`SET ... PXAT` 是 Redis 6.0+ 才认的语法，5.0.4 直接
  `ERR syntax error`。第二步失败就把刚写进去的键删掉——留一个永不过期的会话键，等于把
  "过期即回收"换成"泄漏"，而且不会有任何用例变红。
- 需要端口没覆盖的命令时用公开的 `ask()`（运维取证也用 `scan_keys()`）；除此之外不要绕端口写键。

## 测试怎么跑

- 免服务端（CI 与本地默认）：`moon test --target wasm` ⇒ RS1–RS8 会**打印 SKIP 并计入通过**。
- 真机（必须有一台只归自己的 redis）：`bash scripts/redis-gate.sh`——它把任何 SKIP 判成失败，
  并固定要求 `MT_REDIS_HOST`。两台服务端都要跑过：本机沙箱 Redis 8.0.5 与开发库 Redis 5.0.4。
  用例自带清理，收尾会自证该 realm 名下无残留。
- 负向对照已做过：停掉服务端后 RS1–RS8 正好 8 条转红，说明这套断言不是空转。

## 还没接的东西（不是遗漏，是范围）

- **不进一键包**：`mldong-moon-jeeflow` 的 compose 目前没有 redis 服务，L2 跑批仍带
  `--no-redis`，跨栈门禁那三格显式 SKIP 的结构性依据不变。真要多实例共享会话，
  那是一次独立的改动（compose + L2 口径 + 三格 SKIP 依据要一起改）。
- **不发布**：`.github/workflows/publish.yml` 仍只发四模块，本模块不在发版链里；
  要用它上线得先把它接进发布拓扑序（`store` → 本模块）与 `docs-check.sh` 的模块清单。
- 使用骨架（与 RS1 同源，随包体文档放着，未纳入 `docs-check` 的真编译清单，故不写成可复制即跑的样板）：

```moonbit nocheck
let store = @redis_store.RedisStore::open("user", "127.0.0.1", db=0)
defer store.close()
let auth = @app.TokenAuth::new("user", @app.TokenConfig::default(), store, provider, @style.opaque_style())
```
