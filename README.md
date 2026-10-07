# moon-token

MoonBit 生态的**登录态 / 会话标准件**。DDD 分层、async-first 契约、零第三方运行时依赖
（只依赖官方 `moonbitlang/async`），本地 `moon add` 即用，不需要任何外部服务。

English summary: a login-state and session toolkit for MoonBit — layered DDD (aggregates,
pure domain policies, async storage port), pluggable storage, exact logout reasons
(kicked / superseded / expired never collapse into "not logged in"), multi-realm sessions,
a route-guard DSL, and domain events. backends are pluggable: the in-memory store ships in the
contract module, and a file-backed store (no Redis, no MySQL) persists sessions across
restarts; Redis and SQL drivers are reserved extension points on the same port, to be picked up
once third-party drivers mature.

## 特性

| 能力 | 说明 |
|---|---|
| 双向映射 | `token → loginId` 正查 + `loginId → token 族` 反查，踢人/顶人/在线列表全靠反查 |
| 会话分层 | 账号级会话 + 令牌级会话；设备维度是反查族内的分组 |
| 双层时效 | 签发时效 `timeout` + 活跃时效 `active_timeout`（**活跃时效只在 `renewal = IdleMark` 档判**，默认档不看它）；"记住我"是长时效档 |
| 精确反馈 | 被踢 / 被顶 / 过期 / 封禁各报各的原因，不塌成"未登录" |
| 两种踢人粒度 | `kickout` 按账号+设备，`kickout_token` 按一枚 token——管理端"在线用户"页点一行只撤那一行，同设备其它会话不动 |
| 并发三态 | `Coexist`（默认共存）/ `Supersede`（顶人下线）/ `Shared`（同设备共用一个 token） |
| 滑动续期 | `SlideOnAccess`（带节流窗，默认 60s）/ `IdleMark`（活跃标记） |
| 可插拔存储 | async 仓储端口 + 意图补丁（`FamilyPatch`），换后端不改业务代码；已交付**内存**与**文件**两个后端 |
| 全量轮转 | `rotate` 换新整对，旧 access 与旧 refresh 同时失效；**不校验绑定 access 是否存活** |
| 守卫 DSL | 路径模式 + 断言闭包链，纯逻辑、不绑定任何 web 框架 |
| web 适配 | `mldong/moon-token-moonback`：moonback 逐路由守卫、主体进请求上下文、失败只映射状态码 |
| 领域事件 | 7 个事实事件，落库后 fire，观察者异常不影响主流程 |
| 多账号体系 | `realm` 维度实例化，键位前缀隔离 |

## 安装

四个已发布模块按需引（都发到 mooncakes.io，包页面即模块目录的 README）：

```bash
moon update
moon add mldong/moon-token             # 核心：应用层用例、领域裁决、守卫、事件、令牌风格
moon add mldong/moon-token-store       # 契约与内存适配器（核心包已依赖，通常无需单独加）
moon add mldong/moon-token-store-file  # 文件后端：内存为主 + 写穿透，重启不丢会话
moon add mldong/moon-token-moonback    # moonback 适配层：逐路由守卫、主体进请求上下文
```

要跑 async 用例或服务另需 `moon add moonbitlang/async`。
包页面：https://mooncakes.io/docs/mldong/moon-token （其余三个同名前缀）。

工具链要求：`moonc` **不低于 0.10.14**（`moon version --all` 查看；CI 装官方 latest）。
本仓库在 `preferred_target = "wasm"` 下开发与测试——native 目标在 Windows 需要 MSVC 工具链，
那档读数由 CI 的 Linux job 出。async 运行时来自官方 `moonbitlang/async`。

## 最小用法

```moonbit
// 包别名（moon.pkg）：app / style / guard 取自 mldong/moon-token，
// port / memory 取自 mldong/moon-token-store；跑 async 用例另需
// moon add moonbitlang/async

// 1. 装一个存储（内存实现；Redis / SQL 后端是端口上预留的口子，等第三方驱动库稳定再实现）
let store = @mem.MemoryStore::new("user")

// 2. 权限源由业务实现（端口是 async，查库不用绕路）
pub(all) struct MyPerms {
  permissions : Array[String]
  roles : Array[String]
}

pub impl @port.PermissionProvider for MyPerms with fn get_permissions(
  self,
  _login_id,
  _device,
  _extra,
) {
  self.permissions
}

pub impl @port.PermissionProvider for MyPerms with fn get_roles(self, _login_id, _device, _extra) {
  self.roles
}

pub impl @port.PermissionProvider for MyPerms with fn is_super_admin(
  _self,
  _login_id,
  _device,
  _extra,
) {
  false
}

// 没有这一行，点号调用会报 implicit_impl_as_method；本仓零警告口径下它是错误
pub extend MyPerms with @port.PermissionProvider::{
  get_permissions,
  get_roles,
  is_super_admin,
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

// 6. 守卫：保护面 + 豁免，然后编排一次请求（不通过就抛，原因精确到档）
let route_guard = @guard.RouteGuard::new()
  .match_pattern("/api/**")
  .not_match_pattern("/api/public/**")

@guard.run_guard(auth, route_guard, {
  path: fn() { "/api/user/info" },
  header: fn(name) { if name == "Authorization" { Some(result.token) } else { None } },
}) |> ignore
```

## 完整可运行示例

`examples/cmd/main` 是一个手写十行路由的最小 HTTP 服务（不引任何 web 框架——库本身零 web 依赖），
把库的每个用例都露成一个端点：

```bash
moon run --target wasm examples/cmd/main      # 起在 http://127.0.0.1:18890
bash examples/curl.sh                         # 另开终端：13 步端对端剧本
```

`examples/curl.sh` 那 13 步就是本库的行为说明书——每步都断言**精确原因**而不是"有没有报错"：

| 步 | 动作 | 断言到的原因 |
|---|---|---|
| 2 | 无 token 打 `/api/user/info` | `AbsentToken` |
| 3 | 无 token 打 `/api/public/ping` | 放行（守卫的豁免臂 `not_match_pattern`） |
| 4 | 登录 | 拿到 access + refresh 整对（各 40 字符） |
| 6 | `/whoami` | 业务只供数、AND 裁决在库 |
| 7–8 | 轮转后旧 access 再用 | `UnknownToken`（全量轮转＝旧对同废） |
| 9 | 旧 refresh 重放 | `RefreshInvalid`（原子取删） |
| 11 | 被踢方再用 | `KickedOut`（不是笼统未登录） |
| 12 | 同账号另起一枚 | 仍有效（默认 `Coexist`） |
| 13 | 注销后再用 | `UnknownToken`（与「被踢」分得开：注销删键、踢人落墓碑） |

要引框架的那一条腿也在 `examples/`：`cmd/moonback-demo` 把守卫挂在 moonback 的真路由上，
逐格断 **HTTP 状态码**（401/403/404/200 分得开是适配层的合同，不是库的合同）：

```bash
moon run --target wasm examples/cmd/moonback-demo      # 起在 http://127.0.0.1:18891
bash scripts/mw-smoke.sh                      # 另开终端：豁免/两腿/推导/例外/OR/角色/超管/注销
```

## 文档

用法、机制与取舍写在 `docs/` 下，按"先能跑通 → 再懂为什么这样设计"的顺序排：

| 文档 | 讲什么 |
|---|---|
| [快速开始](docs/quick-start.md) | 装好、五分钟跑通一条完整链，逐步给真读数 |
| [核心概念](docs/concepts.md) | realm、access/refresh 整对、反查族、双层时效、键位形状（含 `P:` 授权快照与 `Z` 活会话索引） |
| [登录与并发策略](docs/login-and-concurrency.md) | `Coexist` / `Supersede` / `Shared` 三态与各自适用场景 |
| [会话与踢人](docs/session-management.md) | 在线列表、设备列表、token 会话/账号会话读写、踢/顶/封禁/解禁 |
| [刷新与轮转](docs/refresh-rotation.md) | 全量轮转语义、重放防护、为什么**不**校验绑定的 access 是否存活 |
| [权限与角色](docs/permissions.md) | SPI 供数、`has_*` 与 `check_*` 两条路、AND/OR 裁决 |
| [路由守卫](docs/route-guard.md) | 模式匹配、豁免优先级、怎么接到你选的 web 框架上 |
| [路由权限策略](docs/route-policy.md) | 约定推导（`/api/orders/save` ⇒ `api:orders:save`）+ 例外清单覆盖；推导规则可换；perms 与 roles 的叠加规则 |
| [领域事件](docs/events.md) | 7 个事件、码值表、"落库后 fire"与观察者异常处理 |
| [存储端口](docs/storage-port.md) | `TokenStore` 契约、`FamilyPatch` 意图补丁、惰性过期两档、怎么写自己的后端 |
| [错误词汇表](docs/error-vocabulary.md) | 7 个未登录原因 + 6 类错误，以及映射成响应码的建议 |
| [配置与默认值](docs/configuration.md) | 十三项配置的默认值与定这个值的理由 |
| [时钟与熵源](docs/clock-and-entropy.md) | 可注入时钟怎么用、三档目标的熵源差异与 `abort` 守卫 |
| [测试指南](docs/testing.md) | 三场景怎么落地：注入时钟、计数型 store、断言精确原因 |
| [文件后端](docs/file-store.md) | 零 Redis/MySQL 的持久化：内存为主 + 写穿透、三条实测边界（fsync 代价、原子改名、键不落文件名） |
| [moonback 集成](docs/moonback-integration.md) | 逐路由守卫 vs App 全局中间件、wasm 顶层 `let` 无熵、cookie 只是载体、失败响应怎么换 |
| [数据模型](docs/data-model.md) | 六类记录字段、关系、TTL 公式、Redis/SQL 物理映射、变更纪律 |
| [常见问题](docs/faq.md) | 集群、多实例、序列化兼容、与 JWT 的取舍 |

## 模块与文档在哪

本仓一个 git 仓库、四个 MoonBit 模块，**发布到 mooncakes 的包根就是模块目录**，
所以每个已发布模块自己带一份 README（mooncakes 页面渲染那份，不是本文件）：

| 模块 | 目录 | 发布名 | 说明 |
|---|---|---|---|
| 核心 | `core/` | `mldong/moon-token` | 应用层用例、领域模型与裁决、守卫、事件、token 风格 → [模块 README](core/README.md) |
| 存储契约 | `store/` | `mldong/moon-token-store` | `TokenStore` 端口、共享内核（值对象/键位/补丁/错误词汇/线格式）、内存适配器 → [模块 README](store/README.md) |
| 文件后端 | `store-file/` | `mldong/moon-token-store-file` | 内存为主 + 写穿透的文件持久化 → [模块 README](store-file/README.md) |
| web 适配 | `moonback/` | `mldong/moon-token-moonback` | moonback 逐路由守卫、主体进请求上下文、状态码映射 → [模块 README](moonback/README.md) |
| 示例 | `examples/` | 不发布 | 两个可运行服务：`cmd/main`（手写路由 + 13 步 curl 剧本）、`cmd/moonback-demo`（框架守卫 + 状态码矩阵） |

`docs/` 那 18 篇**不在发布包里**（模块 zip 只含模块目录），所以四个模块 README 里的文档链接
一律给 GitHub 绝对地址。这五处 README 与 `docs/*.md` 同受 `scripts/docs-check.sh` 管：
里面的每个 `moonbit` 块都会被逐字灌进"只依赖注册表已发布件"的独立工程真编译真跑。

## 设计与规范

分层、端口形状、默认值口径与测试矩阵见仓库内文档；本 README 只保证**照着敲就能跑**。

```bash
bash scripts/gate.sh     # 本地门禁：零警告 + 用例条数与矩阵一致 + 0 failed + 文档真跑
```

## 持续集成

`.github/workflows/publish.yml` 一条流水做完两件事，`verify` 是 `publish` 的硬前置：

| 阶段 | 覆盖 |
|---|---|
| 检查 | `moon check --target wasm`——**零警告口径**，出现 `Warning` 即红 |
| 构建 | `moon build`，wasm 与 native 双档 |
| 测试 | `moon test`，wasm 与 native 双档，并**断言用例条数**（wasm-gc 档会静默丢弃 `async test` 还报 passed，所以条数是硬判据、不是顺带看一眼） |
| 可复现 | README 那段最小用法 + `docs/` 全部代码块 + 四个模块 README，逐字灌进独立工程真编译真跑，同样判零警告 |

触发方式：推 `v*.*.*` tag ⇒ 检查通过就发布到 mooncakes；`workflow_dispatch` ⇒ 默认只检查，勾 `publish` 才发。
发布之后还会**只依赖注册表已发布件**再跑一遍文档检查——那一步就是"用户今天照文档敲能不能跑"的证据。

## 已知限制

- **存储交付了两档，都没做跨实例共享**。内存版重启即清零；文件版（`store-file`）在**同机同目录**内
  一致。多实例共享会话要靠 Redis 后端，但那是端口上**预留的口子**、不是排期里的下一版：
  等第三方 Redis / MySQL 库稳定后再实现（届时业务代码与适配接口一行都不用改）。
- **熵源分档**：默认 `opaque_style()` 取平台熵，取不到即 `abort`（绝不静默回落到固定种子）。
  `wasm-gc` 档无平台熵源，需改用 `opaque_style_with_seed` 或 `opaque_style_with` 显式注入；
  Windows native 目标需 MSVC 工具链（`rand_s`），Linux/CI 与 wasm 档不受影响。
- 随机流是 core 提供的 **ChaCha8（8 轮变体）**，本项目不宣称其等同 ChaCha20 强度。
- 不做注解式鉴权（语言无注解，这是语言事实）；不做 JWT——令牌是不透明随机串 + 服务端会话。
  web 框架适配已交付 moonback 那一层（`mldong/moon-token-moonback`），其余框架照它的形状接。

## 许可与来源

Apache-2.0，见 [LICENSE](LICENSE)。

本项目未移植、未翻译、未复制任何第三方代码；发布包里不含 vendored 的第三方源
（依赖只有官方 `moonbitlang/async` 与 `moonbitlang/moonback`，各自按其许可证条款正常引用），
因此没有第三方许可证的继承义务。分层结构、存储端口形状、意图补丁枚举、错误词汇与接口命名都是本仓自持的；
每个默认值与判定口径"为什么这样定"记在 `docs/data-model.md` 的决策表里。
