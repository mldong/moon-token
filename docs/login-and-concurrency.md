# 登录与并发策略

登录这件事在本库里只有一个入口 `login`，但**同一个人再登录一次会发生什么**由配置决定，
不由调用方临场决定——这是并发策略存在的意义：把"允许多端在线"这条业务规则钉在一个地方。

本页代码块由 `scripts/docs-check.sh` 逐块真编译真跑（对注册表已发布件）。

```moonbit
fn perms() -> @app.TokenAuth[@mem.MemoryStore, P] {
  let p : P = { permissions: ["user:info"], roles: ["demo"] }
  @app.TokenAuth::new("user", @app.TokenConfig::default(), @mem.MemoryStore::new("user"), p, @style.opaque_style())
}

pub(all) struct P {
  permissions : Array[String]
  roles : Array[String]
}

pub impl @port.PermissionProvider for P with fn get_permissions(self, _login_id, _device, _extra) {
  self.permissions
}

pub impl @port.PermissionProvider for P with fn get_roles(self, _login_id, _device, _extra) {
  self.roles
}

pub impl @port.PermissionProvider for P with fn is_super_admin(
  _self,
  _login_id,
  _device,
  _extra,
) {
  false
}

pub extend P with @port.PermissionProvider::{
  get_permissions,
  get_roles,
  is_super_admin,
}
```

## 三种策略，各一句话

| 策略 | 同账号再次登录时 | 典型场景 |
|---|---|---|
| `Coexist`（默认） | 各签一枚，互不影响；反查族里多一个成员 | 网页 + App + 平板同时在线 |
| `Supersede` | 先把该账号既有 token 全部落成"被顶"墓碑，再签新的 | 单账号只许一处登录（考试、支付、政企） |
| `Shared` | **同设备**返回同一枚（`reused=true`，不新签）；换设备才另签 | 同端重复打开不该攒会话；配合反查族天然去重 |

```moonbit
fn auth_with(concurrent : @port.ConcurrentPolicy) -> @app.TokenAuth[@mem.MemoryStore, P] {
  let cfg = @app.TokenConfig::default()
  cfg.concurrent = concurrent
  let p : P = { permissions: ["user:info"], roles: ["demo"] }
  @app.TokenAuth::new("policy", cfg, @mem.MemoryStore::new("policy"), p, @style.opaque_style())
}
```

> `TokenConfig` 的字段是 `mut` 的，改配置不需要 `let mut`——结构体在 MoonBit 里是引用语义。
> 但**每个 realm 一个实例**：配置挂在实例上，两个实例共用一个 store 才会看到彼此的会话。

## 各策略跑出来是什么样

```moonbit
async fn coexist_shape() -> (Bool, Bool, Int) raise {
  let auth = auth_with(@port.Coexist)
  let a = auth.login("u1", device="pc")
  let b = auth.login("u1", device="phone")
  (a.token != b.token, auth.is_login(a.token), (auth.get_token_list_by_login_id("u1")).length())
}

async fn supersede_shape() -> (String, String) raise {
  let auth = auth_with(@port.Supersede)
  let old = auth.login("u2", device="pc")
  let fresh = auth.login("u2", device="phone")
  (
    auth.check_login(old.token) catch { err => err.message() },
    auth.check_login(fresh.token),
  )
}

async fn shared_shape() -> (Bool, Bool) raise {
  let auth = auth_with(@port.Shared)
  let first = auth.login("u3", device="pc")
  let again = auth.login("u3", device="pc")
  let other = auth.login("u3", device="phone")
  (first.token == again.token && again.reused, first.token != other.token)
}

async test "Coexist：两枚都有效，反查族数到 2" {
  let (different, old_alive, online) = coexist_shape()
  assert_true(different)
  assert_true(old_alive)
  assert_eq(online, 2)
}

async test "Supersede：被顶方拿到 SupersededByLogin，不是含糊未登录" {
  let (old_reason, fresh_login) = supersede_shape()
  assert_eq(old_reason, "not login: SupersededByLogin")
  assert_eq(fresh_login, "u2")
}

async test "Shared：同设备复用同一枚，换设备另签" {
  let (reused_same_device, other_device_differs) = shared_shape()
  assert_true(reused_same_device)
  assert_true(other_device_differs)
}
```

被顶的 token **不是被删掉**，而是落成墓碑状态，保留期内（`kick_grace`，默认 5 分钟）再拿来用，
读到的是 `SupersededByLogin`；过了保留期墓碑才被回收，那时读到的才是 `UnknownToken`。
这条区分对前端很重要：前者该提示"你的账号在别处登录"，后者该直接跳登录页。

三档策略都接受 `login(extra=...)`（会话级附加属性，用途见 [权限与角色](permissions.md) §7）：
`Coexist` / `Supersede` 本来就是新签，属性随新会话带进去；`Shared` 命中复用时**token 不变但属性换成
最近一次登录那一份**——与 mldong 各栈"每次登录重写整份 LoginUser"同语义（用例 A38 钉住）。
换属性不会自动作废权限快照，要显式 `invalidate_grants`。

## `remember`：不是"多签一枚"，是换一档时效

```moonbit
async fn remember_span() -> (Int64, Int64) raise {
  // 时效类断言必须注入时钟：真实时钟下两次 login 之间会漂 1ms，
  // "差值恰好等于 30d - 6h"这种断言就会偶发红（本仓的门禁真被它红过一次）。
  let a = perms()
  let cell = 1_700_000_000_000L
  @port.set_clock(Some(fn() { cell }))
  let short = a.login("u4", device="pc", remember=false)
  let long = a.login("u5", device="pc", remember=true)
  @port.set_clock(None)
  (short.expire_at - cell, long.expire_at - cell)
}

async test "remember=true 走长时效档：6h 与 30d" {
  let (short_span, long_span) = remember_span()
  assert_eq(short_span, @port.Duration::from_hours(6L).to_millis())
  assert_eq(long_span, @port.Duration::from_days(30L).to_millis())
}
```

`remember` 只换签发时效（`timeout` → `remember_timeout`），**不**改变并发策略，也**不**多签一枚 token。
默认值 6h / 30d 的理由见 [配置与默认值](configuration.md)。

## 设备维度：归一化与"空设备"

`device` 是反查族里的分组键。省略或给空白时归一到 `default`——同一个人不该因为一个空格被当成两台设备。

```moonbit
async fn device_normalization() -> Bool raise {
  let auth = auth_with(@port.Shared)
  let a = auth.login("u6", device="")
  let b = auth.login("u6", device="   ")
  let c = auth.login("u6")
  a.token == b.token && b.token == c.token
}

async test "空串/纯空白/省略三者是同一台设备" {
  assert_true(device_normalization())
}
```

而 `kickout` / `logout_by_id` / `supersede` 的 `device` 参数含义相反：**省略＝不限设备**（对该账号全部 token 生效）。
同一个参数在"签发"处是分组键、在"批量操作"处是过滤器，这是本库唯一一处需要记住的语义分叉。

## 下一步

- 拿到 token 之后怎么批量操作：[会话与踢人](session-management.md)
- 两枚 token 怎么换新：[刷新与轮转](refresh-rotation.md)
- 为什么默认是 `Coexist`：[配置与默认值](configuration.md)
