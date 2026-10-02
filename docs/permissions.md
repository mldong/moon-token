# 权限与角色

一条分工：**给数是业务的事，裁决是库的事**。库不认识 `user:info` 是什么，它只问业务要一个字符串数组，
然后按调用方要求的组合方式（AND / OR）判"够不够"。

本页代码块由 `scripts/docs-check.sh` 逐块真编译真跑（对注册表已发布件）。

## 1. 供数端口：一个 async trait，三个方法

```moonbit
pub(all) struct Perms {
  by_user : Map[String, Array[String]]
  roles_by_user : Map[String, Array[String]]
}

pub impl @port.PermissionProvider for Perms with fn get_permissions(
  self,
  login_id,
  _device,
) {
  match self.by_user.get(login_id) {
    None => []
    Some(v) => v
  }
}

pub impl @port.PermissionProvider for Perms with fn get_roles(self, login_id, _device) {
  match self.roles_by_user.get(login_id) {
    None => []
    Some(v) => v
  }
}

pub impl @port.PermissionProvider for Perms with fn is_super_admin(
  _self,
  _login_id,
  _device,
) {
  false
}

pub extend Perms with @port.PermissionProvider::{
  get_permissions,
  get_roles,
  is_super_admin,
}

fn auth() -> @app.TokenAuth[@mem.MemoryStore, Perms] {
  let p : Perms = {
    by_user: Map::from_array([
      ("demo", ["user:info", "user:list"]),
      ("vip", ["user:info", "user:list", "order:read"]),
      ("boss", ["user:info", "user:list", "order:read", "sys:manage"]),
    ]),
    roles_by_user: Map::from_array([
      ("demo", ["user"]),
      ("vip", ["user", "vip"]),
      ("boss", ["user", "vip", "admin"]),
    ]),
  }
  @app.TokenAuth::new("user", @app.TokenConfig::default(), @mem.MemoryStore::new("user"), p, @style.opaque_style())
}
```

三处形状必须照做，否则编译器不认：

- **实现头不写 `async`**。契约里声明的是 `async fn`，实现处只写 `fn`——`async` 由 trait 决定。
  这么设计是因为真实实现要查库（异步 IO），而演示实现查内存表；两者在库里同权。
- **`pub(all) struct`**。跨包要能构造它，光 `pub struct` 只暴露类型不暴露字段。
- **`pub extend ... with ...`**。没有这一行，`perms.get_permissions(...)` 这种点号调用会报
  `implicit_impl_as_method`；本仓零警告口径下它是错误。

第三个方法 `is_super_admin` 库里不给任何推导：**"谁是超管"是业务事实**（常见形状是用户表上有一个
管理员类型字段）。演示实现一律写死 `false`，真实实现返回你自己那个判据的结果。
库只把这个布尔原样存进快照，并在权限/角色校验前读它。

## 2. 授权快照：一枚会话只问业务一次

三个方法的返回值拼成一份快照，落在 `{realm}:P:{token}` 上，TTL 跟这条会话同寿。
同一次鉴权里判权限、判角色、再判一次权限，读的都是同一份快照，**不会再回业务库**：

```moonbit
async fn snapshot_counted() -> (Bool, Bool, Bool) raise {
  let a = auth()
  let t = a.login("demo", device="pc").token
  let first = a.has_permission(t, ["user:info"])
  let again = a.has_permission(t, ["user:info"])
  let roles = a.has_role(t, ["user"])
  (first, again, roles)
}

async test "判定不重复问业务：权限集与超管位来自同一份快照" {
  let (first, again, roles) = snapshot_counted()
  assert_true(first)
  assert_true(again)
  assert_true(roles)
}
```

三条边界得先知道：

- **业务改了数据不会自己生效**。给某人加了一个角色，他的老会话仍看见旧数，直到调
  `invalidate_grants(login_id, device?)` 或者他重新登录。这是缓存换来的代价，属于契约。
- **快照不是权威**。它只回答"要不要去问业务"，从不回答"放不放行"；解不出来就按 miss 重问，
  不会因为缓存坏掉而放行或拦人。主体身份（登录号）始终以 `T:` 为准。
- **超管位在快照里，不在会话记录里**。`T:`/`A:` 不承载业务身份位；中间件判超管读
  `authenticate(token)` 的第二项，不用回调业务库。超管是否跳过权限/角色校验由
  `TokenConfig::super_bypass` 决定（默认开；关掉后一视同仁）。

```moonbit
async fn who_is_boss() -> (Bool, Array[String]) raise {
  let a = auth()
  let t = a.login("boss", device="pc").token
  let (_, record) = a.authenticate(t)
  (record.super_admin, record.perms)
}

async test "中间件要的主体信息：认证一次同时拿到登录号与授权集" {
  let (super_admin, perms) = who_is_boss()
  assert_false(super_admin)    // 上面的演示实现把 is_super_admin 写死 false
  assert_eq(perms.length(), 4)
}
```

作废快照的形状（改完角色/权限之后调）：

```moonbit
async fn drop_snapshot() -> Int raise {
  let a = auth()
  let t = a.login("demo", device="pc").token
  a.has_permission(t, ["user:info"]) |> ignore
  a.invalidate_grants("demo")
}

async test "invalidate_grants 返回清掉的份数" {
  assert_eq(drop_snapshot(), 1)
}
```

这段只演示调用形状。**"是否真的一次都没多问"要靠计数探针才测得出来**——缓存彻底坏了判定照样对，
所以库自己的用例（`core/app/grants_test.mbt` A31–A33）断言的是"问了几次"，写业务测试时照这个尺度来，
细节见 [测试策略](testing.md)。

## 3. 两条路：`has_*` 拿 bool，`check_*` 抛错

| 用途 | 返回 | 失败时 |
|---|---|---|
| `has_permission(token, required, mode?)` | `Bool` | 不抛（缺权限给 false） |
| `check_permission(token, required, mode?)` | `Unit` | 抛 `NotPermission(缺失项)` |
| `has_role(token, required, mode?)` | `Bool` | 同上 |
| `check_role(token, required, mode?)` | `Unit` | 抛 `NotRole(缺失项)` |
| `authenticate(token)` | `(login_id, PermissionRecord)` | 抛 `NotLogin` / `Disabled` |
| `check_principal(record, perms, perm_mode, roles, role_mode)` | `Unit` | 抛 `NotPermission` / `NotRole` |

后两条是给 **web 适配层**备的：中间件通常已经 `authenticate` 过（要把权限集与超管位交给业务），
再走 `check_access` 就会把同一枚会话读第二遍；`check_principal` 是纯判定那半边，一次存储读都不做。
接好的那一份见 [moonback 集成](moonback-integration.md)。

```moonbit
async fn two_ways() -> (Bool, String) raise {
  let a = auth()
  let t = a.login("demo", device="pc").token
  let quiet = a.has_permission(t, ["user:info", "order:read"])
  // check_permission 成功时给 Unit，所以取"抛出来的话"必须用块式 try：
  // 表达式级 `x catch { }` 的两个臂必须同类型，Unit 配不上 String
  let loud = try {
    a.check_permission(t, ["user:info", "order:read"])
    "没抛"
  } catch {
    err => err.message()
  }
  (quiet, loud)
}

async test "同一个缺口的两种表达" {
  let (quiet, loud) = two_ways()
  assert_false(quiet)
  assert_eq(loud, "no permission: order:read")
}
```

`NotPermission` 的载荷是**缺的那一项**，不是"权限不足"四个字——前端要能直接告诉用户缺什么，
日志也要能一眼定位。

## 4. AND 与 OR

```moonbit
async fn modes() -> Array[Bool] raise {
  let a = auth()
  let t = a.login("vip", device="pc").token
  [
    a.has_permission(t, ["user:info", "order:read"]),
    a.has_permission(t, ["order:read", "sys:manage"], mode=@port.Or),
    a.has_permission(t, ["sys:manage"], mode=@port.Or),
    a.has_permission(t, []),
  ]
}

async test "AND 全中才过、OR 中一即过、空 required 恒过" {
  let r = modes()
  assert_true(r[0])
  assert_true(r[1])
  assert_false(r[2])
  assert_true(r[3])
}
```

空 `required` 恒真是刻意的：**"不要求任何权限"和"要求一个不存在的权限"不能都判不过**，
否则守卫的追加断言写起来要处处特判空集。

## 5. 权限判定之前一定先过鉴权

`has_permission` 内部第一步就是 `check_login`。所以：

```moonbit
async fn unauthenticated() -> String {
  let a = auth()
  try {
    a.has_permission("not-a-token", ["user:info"]).to_string()
  } catch {
    err => err.message()
  }
}

async test "未登录时抛的是鉴权错，不是返回 false" {
  assert_eq(unauthenticated(), "not login: UnknownToken")
}
```

这条容易被误解成"has_* 永远不抛"。它不抛的是**权限不够**；**身份不成立**照样抛。
把它当纯 bool 函数用 `x catch { _ => false }` 一口吞掉，就会把"该跳登录页"误判成"该提示无权限"。

## 6. `device` 参数：按设备给不同数

供数端口拿得到 `(login_id, device?)`。同一个人从 App 和从后台进来，权限集可以不同——
这件事在库里不需要任何特判，业务在 `get_permissions` 里按 device 分支即可。

```moonbit
pub(all) struct DeviceAware {
  app_perms : Array[String]
  web_perms : Array[String]
}

pub impl @port.PermissionProvider for DeviceAware with fn get_permissions(
  self,
  _login_id,
  device,
) {
  match device {
    None => self.web_perms
    Some(d) => if d.id == "app" { self.app_perms } else { self.web_perms }
  }
}

pub impl @port.PermissionProvider for DeviceAware with fn get_roles(
  _self,
  _login_id,
  _device,
) {
  []
}

pub impl @port.PermissionProvider for DeviceAware with fn is_super_admin(
  _self,
  _login_id,
  _device,
) {
  false
}

pub extend DeviceAware with @port.PermissionProvider::{
  get_permissions,
  get_roles,
  is_super_admin,
}

async fn by_device() -> (Bool, Bool) raise {
  let p : DeviceAware = { app_perms: ["user:info"], web_perms: ["user:info", "sys:manage"] }
  let a = @app.TokenAuth::new(
    "user",
    @app.TokenConfig::default(),
    @mem.MemoryStore::new("user"),
    p,
    @style.opaque_style(),
  )
  let from_app = a.login("boss", device="app").token
  let from_web = a.login("boss", device="web").token
  (
    a.has_permission(from_app, ["sys:manage"]),
    a.has_permission(from_web, ["sys:manage"]),
  )
}

async test "同一个人按设备拿到不同权限集" {
  let (app, web) = by_device()
  assert_false(app)
  assert_true(web)
}
```

## 7. 角色与权限是两套数，不要混用

`get_roles` 与 `get_permissions` 各查各的，`has_role` 只吃前者。把它们塞进同一个数组里
"用前缀区分"是能跑的，但错误载荷 `NotRole(user)` 与 `NotPermission(user)` 就分不开了——
运维查问题时这条区分很值钱。

## 8. 在守卫里追加权限断言

`RouteGuard::check` 收的是同步闭包，而 `check_permission` 是 async，所以**追加断言写在处理器里**、
守卫只管身份；或者反过来，把身份交给守卫、把权限在处理器里判一次。示例服务走的是后者
（`/whoami` 端点）。形状见 [路由守卫](route-guard.md)。
