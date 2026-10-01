# moon-token

MoonBit 生态的**登录态 / 会话标准件**。DDD 分层、async-first 契约、零第三方运行时依赖
（只依赖官方 `moonbitlang/async`），本地 `moon add` 即用，不需要任何外部服务。

English summary: a login-state and session toolkit for MoonBit — layered DDD (aggregates,
pure domain policies, async storage port), pluggable storage, exact logout reasons
(kicked / superseded / expired never collapse into "not logged in"), multi-realm sessions,
a route-guard DSL, and domain events. v1 ships the in-memory store; durable backends
(MySQL/Postgres/SQLite via a transactional driver, Redis via Lua) are the next round.

## 特性

| 能力 | 说明 |
|---|---|
| 双向映射 | `token → loginId` 正查 + `loginId → token 族` 反查，踢人/顶人/在线列表全靠反查 |
| 会话分层 | 账号级会话 + 令牌级会话；设备维度是反查族内的分组 |
| 双层时效 | 签发时效 `timeout` + 活跃时效 `active_timeout`；"记住我"是长时效档 |
| 精确反馈 | 被踢 / 被顶 / 过期 / 封禁各报各的原因，不塌成"未登录" |
| 并发三态 | `Coexist`（默认共存）/ `Supersede`（顶人下线）/ `Shared`（同设备共用一个 token） |
| 滑动续期 | `SlideOnAccess`（带节流窗，默认 60s）/ `IdleMark`（活跃标记） |
| 可插拔存储 | async 仓储端口 + 意图补丁（`FamilyPatch`），换后端不改业务代码 |
| 全量轮转 | `rotate` 换新整对，旧 access 与旧 refresh 同时失效；**不校验绑定 access 是否存活** |
| 守卫 DSL | 路径模式 + 断言闭包链，纯逻辑、不绑定任何 web 框架 |
| 领域事件 | 7 个事实事件，落库后 fire，观察者异常不影响主流程 |
| 多账号体系 | `realm` 维度实例化，键位前缀隔离 |

## 安装

```bash
moon update
moon add mldong/moon-token
moon add mldong/moon-token-store   # 内存实现（核心包已依赖，通常无需单独加）
```

要求 MoonBit 工具链为当前稳定版（`moon version --all` 查看）。本仓库在
`preferred_target = "wasm"` 下开发与测试；async 运行时来自官方 `moonbitlang/async`。

## 最小用法

```moonbit
// 包别名（moon.pkg）：app / style / guard 取自 mldong/moon-token，
// port / memory 取自 mldong/moon-token-store；跑 async 用例另需
// moon add moonbitlang/async

// 1. 装一个存储（内存实现；v2 起可换事务型/Lua 型后端）
let store = @mem.MemoryStore::new("user")

// 2. 权限源由业务实现（端口是 async，查库不用绕路）
pub(all) struct MyPerms {
  permissions : Array[String]
  roles : Array[String]
}

impl @port.PermissionProvider for MyPerms with fn get_permissions(self, _login_id, _device) {
  self.permissions
}

impl @port.PermissionProvider for MyPerms with fn get_roles(self, _login_id, _device) {
  self.roles
}

// 3. 装配一个账号体系（启动期一次，无反射、无扫描魔法）
// 实现体要在别处构造 ⇒ 必须 pub(all)；记录字面量要有已知目标类型，
// 故先 let 绑类型再当实参传入（裸字面量直接作实参编不过，消费者实测撞过）。
let perms : MyPerms = { permissions: ["user:info"], roles: ["admin"] }

let auth = @app.TokenAuth::new(
  "user",
  @app.TokenConfig::default(),
  store,
  perms,
  @style.opaque_style(),
)

// 4. 登录 / 鉴权（token 显式传参，核心包不依赖任何请求上下文）
let result = auth.login("u1", device="pc")
let login_id = auth.check_login(result.token)   // "u1"

// 5. 反向操作：被操作方下次请求拿到的是精确原因
auth.kickout("u1", device="pc") |> ignore
//   -> NotLogin(KickedOut)，而不是笼统的"未登录"

// 6. 守卫：保护面 + 豁免 + 追加断言
let route_guard = @guard.RouteGuard::new()
  .match_pattern("/api/**")
  .not_match_pattern("/api/public/**")
```

## 完整可运行示例：可视化演示站

一个进程、一个端口、两个门面：`/` 起是**给人看的 HTML 演示站**（MoonBit 服务端直出，
零前端构建、零模板引擎），`/api/**` 与 `/login`、`/kick`、`/logout` 是**给脚本看的 JSON**。
两者共用同一份站点状态与同一套 `RouteGuard`，所以 curl 登录完刷新页面就能看到新会话。

```bash
moon run --target wasm examples/cmd/serve     # 起在 http://127.0.0.1:18891
bash examples/curl.sh                         # 另开终端：正向 / 精确原因 / 页面回归
bash scripts/site-smoke.sh                    # 一把梭：自己起、自己测、自己收
```

演示站上能直接看到的机制（都在 `examples/site/`，是库的一个普通使用者）：

| 页面 | 演什么 |
|---|---|
| 总览 | 依赖方向图 + 实时读数（键位数、事件数、时钟模式） |
| 键位矩阵 | `T:/A:/R:/D:/S:` 五种键的真实载荷与剩余寿命；被踢的墓碑看得见，宽窗过后被回收也看得见 |
| 剧本剧场 | 11 个既定剧本，逐步给「调用 → 精确结果 → 这一步 store 被怎么调」；跑在独立 realm + 独立手动时钟上，不污染站点状态 |
| 守卫模拟 | 改路径 / token / 所需权限，看裁决落到哪一条原因上（`AbsentToken`/`KickedOut`/`SessionExpired`…） |
| 时间机器 | 真实/手动两态时钟。时效类特性（过期、活跃超时、踢人宽窗、续期节流）不能等真时间 |
| 事件流 | 落库后 fire 的事件流水；站点故意多挂一条总会抛错的观察者，用来演"观察者坏掉不带崩主流程" |

`examples/site/state.mbt` 里的 `ObservingStore` 顺带是"端口能被第三方包一层"的活证据：
它只是 `TokenStore` 的另一个实现方，委托内存适配器并记一条调用流水，库那边一行没改。

## 设计与规范

分层、端口形状、默认值口径与测试矩阵见仓库内文档；本 README 只保证**照着敲就能跑**。

```bash
bash scripts/gate.sh     # 本地门禁：零警告 + 用例条数与矩阵一致 + 0 failed
```

## 已知限制

- **v1 只交付内存存储**。进程重启状态清零；持久化后端（事务型、Lua 原子型）在下一轮。
- **熵源分档**：默认 `opaque_style()` 取平台熵，取不到即 `abort`（绝不静默回落到固定种子）。
  `wasm-gc` 档无平台熵源，需改用 `opaque_style_with_seed` 或 `opaque_style_with` 显式注入；
  Windows native 目标需 MSVC 工具链（`rand_s`），Linux/CI 与 wasm 档不受影响。
- 随机流是 core 提供的 **ChaCha8（8 轮变体）**，本项目不宣称其等同 ChaCha20 强度。
- 不做注解式鉴权（语言无注解）；二级认证、JWT 风格令牌、框架中间件适配归下一轮。

## License

Apache-2.0. See [LICENSE](LICENSE).
