# 配置与默认值

`TokenConfig` 十二个字段，每个默认值都不是随手取的——这一页把"值是多少"和"为什么是这个值"放在一起。
本页代码块由 `scripts/docs-check.sh` 逐块真编译真跑（对注册表已发布件）。

```moonbit
fn defaults() -> @app.TokenConfig {
  @app.TokenConfig::default()
}

test "默认值读数（改任何一个都要同步改这里）" {
  let c = defaults()
  assert_eq(c.token_name, "Authorization")
  assert_eq(c.token_prefix, "")
  assert_eq(c.timeout.to_millis(), 21_600_000L)
  assert_eq(c.remember_timeout.to_millis(), 2_592_000_000L)
  assert_eq(c.active_timeout.to_millis(), 0L)
  assert_eq(c.renew_min_interval.to_millis(), 60_000L)
  assert_eq(c.kick_grace.to_millis(), 300_000L)
  assert_eq(c.refresh_timeout.to_millis(), 2_592_000_000L)
  assert_eq(c.max_sessions, 12)
  assert_eq(c.overflow_exit.code(), "logout")
  // 枚举没 derive(Eq)：判等只能 match，或比 code()/to_code() 这类读数
  let is_slide = match c.renewal {
    @port.SlideOnAccess => true
    @port.IdleMark => false
  }
  assert_true(is_slide)
  assert_eq(c.concurrent.code(), "coexist")
}
```

## 十三项

| 字段 | 默认 | 为什么是这个值 |
|---|---|---|
| `token_name` | `"Authorization"` | 不加 `Bearer ` 前缀是刻意的：裸值最省事，且示例/守卫都按它取头 |
| `token_prefix` | `""` | 空＝不剥前缀。要接 Bearer 风格就设成 `"Bearer "`，**精确匹配**（大小写敏感），格式不该由库猜 |
| `timeout` | **6h** | 对齐同类生态 access 档。定 30d 的话滑动续期永远判"不用续"，续期逻辑等于死代码 |
| `remember_timeout` | 30d | "记住我"档的 access 时效，与 refresh 同档，用户一天一登的体感刚好 |
| `active_timeout` | 0（不限） | 默认不启用活跃时效：多数业务不需要"闲置 5 分钟就掉线"。要启用见下面 §3 |
| `renewal` | `SlideOnAccess` | 访问即滑动续期，是同类生态的既得口径 |
| `renew_min_interval` | 60s | **续期节流是契约不是优化**：没有它，每个请求都要写一次库；有它，"到期点前推"最多滞后 60s |
| `kick_grace` | 5min | 被踢的墓碑保留多久。太短→用户看到的提示从"被踢"退化成"未登录"；太长→状态堆积 |
| `concurrent` | `Coexist` | 多端同时在线是常态，默认不该跟用户作对。单点登录请显式改 `Supersede` |
| `refresh_timeout` | 30d | 一次登录最多能续多久（每次轮转重新计时） |
| `max_sessions` | **12**（`-1`＝不限） | 同账号活会话上限，超限按**登录时刻**先进先出注销最早的。没有上限，脚本刷登录就能让族无限增长（内存版是泄漏，Redis 版是成百上千条成员拖慢读取）。可跑示例见 §5 |
| `overflow_exit` | `Logout` | 被上限剔掉的那一枚怎么下线：`Logout`（读作 `UnknownToken`）/ `Kick`（`KickedOut`）/ `Supersede`（`SupersededByLogin`）。可跑示例见 §5 |
| `super_bypass` | **true** | 超管（业务 `is_super_admin` 给真）跳过权限/角色校验，**仍要求已登录**。默认开是同类框架的通行约定；关掉后 `check_permission` / `check_role` / `check_access` 与路由守卫一视同仁。判定用的数是授权快照里的 `super_admin`，不回落业务库（见 [权限与角色](permissions.md) §2） |

时长一律是共享内核的 `Duration`（core 没有 time 包），读毫秒用配套的 `*_ms()`：

```moonbit
test "毫秒读数与 Duration 一致" {
  let c = defaults()
  assert_eq(c.timeout_ms(), c.timeout.to_millis())
  assert_eq(c.kick_grace_ms(), c.kick_grace.to_millis())
  assert_eq(c.renew_min_interval_ms(), c.renew_min_interval.to_millis())
  assert_true(c.active_timeout.is_zero())
}
```

## 1. 改配置：结构体是引用语义

```moonbit
fn single_point_auth() -> @app.TokenConfig {
  let cfg = @app.TokenConfig::default()
  cfg.concurrent = @port.Supersede
  cfg.active_timeout = @port.Duration::from_minutes(15L)
  cfg
}

test "改字段不需要 let mut" {
  let cfg = single_point_auth()
  assert_eq(cfg.concurrent.code(), "supersede")
  assert_eq(cfg.active_timeout_ms(), 900_000L)
}
```

字段本身在结构体定义里是 `mut` 的，所以 `let cfg = ...` 之后照样能改字段——
写 `let mut cfg` 反而会被编译器警告"mut 从未使用"。

**配置挂在 `TokenAuth` 实例上，不挂在全局**。两个 realm 各一套配置互不影响；
同一 realm 请只建一个实例（状态在 `store` 里，实例本身无状态）。

```moonbit
async fn two_realms_two_policies() -> Bool raise {
  let p : P = { permissions: [], roles: [] }
  let loose_cfg = @app.TokenConfig::default()
  let strict_cfg = @app.TokenConfig::default()
  strict_cfg.concurrent = @port.Supersede
  let loose = @app.TokenAuth::new("loose", loose_cfg, @mem.MemoryStore::new("loose"), p, @style.opaque_style())
  let strict = @app.TokenAuth::new("strict", strict_cfg, @mem.MemoryStore::new("strict"), p, @style.opaque_style())
  let a = loose.login("u1", device="pc")
  loose.login("u1", device="phone") |> ignore
  let b = strict.login("u2", device="pc")
  strict.login("u2", device="phone") |> ignore
  // 同一句 check_login，两个 realm 给出不同答案：策略是实例级的
  loose.is_login(a.token) && !strict.is_login(b.token)
}

async test "策略按 realm 独立生效" {
  assert_true(two_realms_two_policies())
}
```

```moonbit
pub(all) struct P {
  permissions : Array[String]
  roles : Array[String]
}

pub impl @port.PermissionProvider for P with fn get_permissions(self, _login_id, _device) {
  self.permissions
}

pub impl @port.PermissionProvider for P with fn get_roles(self, _login_id, _device) {
  self.roles
}

pub impl @port.PermissionProvider for P with fn is_super_admin(
  _self,
  _login_id,
  _device,
) {
  false
}

pub extend P with @port.PermissionProvider::{
  get_permissions,
  get_roles,
  is_super_admin,
}
```

## 2. 续期节流：一个能看见的配置

`renew_min_interval` 的效果不需要读源码，拨一下时钟就能看见到期点动不动。

```moonbit
async fn throttle_window() -> (Bool, Bool) raise {
  let a = auth()
  let t = a.login("u3", device="pc")
  let issued = t.expire_at
  // 窗内访问：到期点不动（不写库）
  a.check_login(t.token) |> ignore
  let after_in_window = (a.get_token_session(t.token)).unwrap().expire_at() == issued
  // 出窗访问：到期点前推
  let cell = @port.now_ms() + a.config.renew_min_interval_ms() + 1000L
  @port.set_clock(Some(fn() { cell }))
  a.check_login(t.token) |> ignore
  let after_out_of_window = (a.get_token_session(t.token)).unwrap().expire_at() > issued
  @port.set_clock(None)
  (after_in_window, after_out_of_window)
}

async test "窗内不写库、出窗才前推" {
  let (held_still, moved) = throttle_window()
  assert_true(held_still)
  assert_true(moved)
}
```

把它设成 0 就是"每个请求都写一次库"。除非你的后端写成本极低且要绝对精确的到期时刻，
否则别关——这条默认值是拿真实流量换出来的。

## 3. 启用活跃时效：`IdleMark` + `active_timeout`

```moonbit
async fn idle_expiry() -> String raise {
  let p : P = { permissions: [], roles: [] }
  let cfg = @app.TokenConfig::default()
  cfg.renewal = @port.IdleMark
  cfg.active_timeout = @port.Duration::from_minutes(5L)
  let a = @app.TokenAuth::new("idle", cfg, @mem.MemoryStore::new("idle"), p, @style.opaque_style())
  let t = a.login("u4", device="pc").token
  let cell = @port.now_ms() + 6L * 60_000L
  @port.set_clock(Some(fn() { cell }))
  let reason = a.check_login(t) catch { err => err.message() }
  @port.set_clock(None)
  reason
}

async test "闲置过阈值即拒，且报的是 ActiveTimeout 不是过期" {
  assert_eq(idle_expiry(), "not login: ActiveTimeout")
}
```

`IdleMark` 与 `SlideOnAccess` 是**两种判据**，不是"开/关续期"：前者只看"多久没动"，
后者只看"到期点在哪"。选错的表现很隐蔽——想要"30 分钟不动就掉线"却配了 `SlideOnAccess`，
结果是用户只要一直在动就永远不掉线。

## 4. 改这些值时请注意

- **`timeout` 缩短不会让已签发的 token 提前失效**：时效记在会话里（绝对到期时刻），改配置只影响新签发的。
- **`kick_grace` 缩短会让"被踢"这个原因更快退化成 `UnknownToken`**：排查线上问题时经常后悔它太短。
- **`concurrent` 从 `Coexist` 改成 `Supersede` 不影响已存在的多枚会话**：策略在签发时生效，不追溯。
- **`token_prefix` 一改，所有旧客户端立刻取不到 token**（报 `AbsentToken`，不是 `UnknownToken`）——
  这个区分能帮你三分钟定位是不是前缀配置的问题。

```moonbit
fn auth() -> @app.TokenAuth[@mem.MemoryStore, P] {
  let p : P = { permissions: ["user:info"], roles: ["demo"] }
  @app.TokenAuth::new("user", @app.TokenConfig::default(), @mem.MemoryStore::new("user"), p, @style.opaque_style())
}
```

## 5. 会话上限与在线枚举

两项配置与两个端口方法是一组：上限管"一个账号能攒多少枚活会话"，枚举管"把在线的人查出来"。

```moonbit
fn capped() -> @app.TokenConfig {
  let cfg = @app.TokenConfig::default()
  cfg.max_sessions = 2            // -1 ＝ 不限
  cfg.overflow_exit = @port.Kick  // 被剔的那枚要能读到"被踢"，而不是退化成"未登录"
  cfg
}

async fn cap_in_action() -> (Bool, Int) raise {
  let p : P = { permissions: [], roles: [] }
  // 时钟必须自己拨。淘汰按登录时刻定序，三次登录若挤进同一毫秒，
  // "谁最老"就退化成按 token 字典序——断言会随机红（CI 就这么抓到过一次）。
  // 基准要取真实量级：从 1000ms 起算的话，还原时钟后这些会话会"瞬间过期一甲子"，
  // 断言会绿得毫无意义（第一版就是这么假绿的）。
  let t : Array[Int64] = [1_700_000_000_000L]
  @port.set_clock(Some(fn() { t[0] }))
  let a = @app.TokenAuth::new(
    "cap",
    capped(),
    @mem.MemoryStore::new("cap"),
    p,
    @style.opaque_style(),
  )
  let first = a.login("u1", device="pc")
  t[0] = t[0] + 1_000L
  a.login("u1", device="pad") |> ignore
  t[0] = t[0] + 1_000L
  a.login("u1", device="tv") |> ignore
  // 读数要在钉住的时钟下取完，最后一步才还原
  let out = (a.is_login(first.token), (a.get_token_list_by_login_id("u1")).length())
  @port.set_clock(None)
  out
}

async test "上限 2：签第三枚时最早那枚已不在线（Kick 档），在线列表仍只剩两枚" {
  let r = cap_in_action()
  assert_false(r.0)
  assert_eq(r.1, 2)
}
```

三档的差别只在**被剔方读到什么**（发起方那边都是正常登录成功）：

| `overflow_exit` | 对端 `check_login` 读到 | 反查族成员 | `T:` 键 |
|---|---|---|---|
| `Logout` | `UnknownToken` | 摘掉 | 删 |
| `Kick` | `KickedOut`（保留窗内） | 摘掉 | 留墓碑，到期＝`now + kick_grace` |
| `Supersede` | `SupersededByLogin` | 摘掉 | 同上 |

Kick / Supersede 也**必须摘成员**：上限数的是"活成员"，墓碑不摘就会被下一次登录重数进去，
于是"上限 3"实际能攒到 `3 + 保留窗内的墓碑数`。摘成员而不动 `T:` 走的是
`FamilyPatch::ForgetTokens`——它和 `RemoveTokens` 的唯一差别就是留不留墓碑。

在线用户列表那一页怎么用 `list_online` / `load_online`，见 `docs/session-management.md`。
