///|
/// MB1–MB9：moonback 适配层的三场景（黑盒，只走公开面）。
///
/// 这一层的承重主张有两条，都得有数字兜着：
/// ① 一次受保护请求**只问业务一次**（权限/角色/超管位全读 `P:` 快照，不回头读会话）；
/// ② 豁免面**没有主体**（`None` 不等于"未登录"——历史上这里塞过路径当 login_id）。
/// 所以判定结果之外，每次都核 `probe.calls`。
///
/// 判决入口取 `@guard.decide` 而不是 `Guard::authorize`：moonback 的 `Context::new` 与
/// `ConnectionInfo` 都不公开，包外造不出 `Request`，硬要测就得真起服务器。
/// `authorize` 只做"`Request` → 两个闭包"这一件事，那条腿由 demo 的冒烟矩阵真跑覆盖。
///
/// 不注入时钟：本组用例不比较到期时刻，登录用的默认 TTL 是小时量级，跑不出计时依赖。

///|
struct MbProbe {
  mut calls : Int
  mut perms : Array[String]
  mut roles : Array[String]
  mut super_admin : Bool
}

///|
let probe : MbProbe = { calls: 0, perms: [], roles: [], super_admin: false }

///|
struct CountingPerms {}

///|
pub impl @port.PermissionProvider for CountingPerms with fn get_permissions(
  _self,
  _login_id,
  _device,
  _extra,
) {
  probe.calls += 1
  probe.perms
}

///|
pub impl @port.PermissionProvider for CountingPerms with fn get_roles(
  _self,
  _login_id,
  _device,
  _extra,
) {
  probe.calls += 1
  probe.roles
}

///|
pub impl @port.PermissionProvider for CountingPerms with fn is_super_admin(
  _self,
  _login_id,
  _device,
  _extra,
) {
  probe.calls += 1
  probe.super_admin
}

pub extend CountingPerms with @port.PermissionProvider::{
  get_permissions,
  get_roles,
  is_super_admin,
}

///|
fn reset_probe(
  perms : Array[String],
  roles : Array[String],
  super_admin : Bool,
) -> Unit {
  probe.calls = 0
  probe.perms = perms
  probe.roles = roles
  probe.super_admin = super_admin
}

///|
type Auth = @app.TokenAuth[@mem.MemoryStore, CountingPerms]

///|
fn mb_auth_with(realm : String, config : @app.TokenConfig) -> Auth {
  @app.TokenAuth::new(
    realm,
    config,
    @mem.MemoryStore::new(realm),
    CountingPerms::{},
    @style.opaque_style(),
  )
}

///|
fn mb_auth(realm : String) -> Auth {
  mb_auth_with(realm, @app.TokenConfig::default())
}

///|
/// 假请求：只喂两个闭包（取路径、取头）。
fn req(path : String, token : String?) -> @core_guard.RequestFns {
  let fns : @core_guard.RequestFns = {
    path: fn() { path },
    header: fn(name) { if name == "Authorization" { token } else { None } },
  }
  fns
}

///|
/// 三档保护面一次给全：豁免（`/login`、`/public/**`）、例外清单（`/sys/user/save`）、其余走推导。
fn policy() -> @core_guard.RoutePolicy {
  (@core_guard.RoutePolicy::new())
    .exempt("/login")
    .exempt("/public/**")
    .rule(@core_guard.RouteRule::make("/sys/user/save", ["sys:user:save"]))
}

///|
/// 被拦下的**精确原因**：只断言"被拒"不够，档位错了也算过。
async fn fail_reason(auth : Auth, pol : @core_guard.RoutePolicy, fns : @core_guard.RequestFns) -> String {
  try {
    let _ = @guard.decide(auth, pol, fns)
    "没抛错"
  } catch {
    err => err.message()
  }
}

///|
async test "MB1 豁免面连 token 都不看：放行但没有主体，业务一次都没被问" {
  reset_probe(["sys:user:save"], [], false)
  let auth = mb_auth("mb1")
  let pol = policy()
  let subject = @guard.decide(auth, pol, req("/login", None))
  assert_true(subject is None, msg="豁免面必须给 None（没有主体）")
  assert_eq(probe.calls, 0, msg="豁免面不该问业务")
  // 带一枚有效 token 走豁免面也一样：不看登录态，也就不建快照
  let token = auth.login("u1", device="pc").token
  assert_true(@guard.decide(auth, pol, req("/public/ping", Some(token))) is None)
  assert_eq(probe.calls, 0)
}

///|
async test "MB2 未登录报 NotLogin：状态 401，而且一次业务都不问" {
  reset_probe(["sys:user:save"], [], false)
  let auth = mb_auth("mb2")
  let loud = fail_reason(auth, policy(), req("/sys/user/save", None))
  assert_eq(loud, "not login: AbsentToken")
  assert_eq(@guard.status_of(@port.NotLogin(@port.AbsentToken)), 401)
  assert_eq(probe.calls, 0, msg="身份不成立就该挡在取数前面")
}

///|
async test "MB3 权限够就过：主体带权限/角色/超管位，两趟判定只问业务一轮" {
  reset_probe(["sys:user:save"], ["user"], false)
  let auth = mb_auth("mb3")
  let token = auth.login("u1", device="pc").token
  let g = @guard.Guard::new(auth, policy())
  assert_eq(g.policy.rule_count(), 1)
  let one = @guard.decide(auth, policy(), req("/sys/user/save", Some(token)))
  let two = @guard.decide(auth, policy(), req("/sys/user/save", Some(token)))
  match one {
    None => fail("权限够应当有主体")
    Some(p) => {
      assert_eq(p.login_id, "u1")
      assert_eq(p.permissions, ["sys:user:save"])
      assert_eq(p.roles, ["user"])
      assert_false(p.super_admin)
    }
  }
  match (one, two) {
    (Some(a), Some(b)) => {
      assert_eq(b.login_id, a.login_id)
      // 快照没失效才会逐项相同；真失效了这里也可能相同，所以承重的是下面的 calls
      assert_true(b.permissions == a.permissions, msg="两趟判定的权限集必须相同")
      assert_true(b.roles == a.roles)
      assert_eq(b.super_admin, a.super_admin)
    }
    _ => fail("两趟都必须给主体")
  }
  // 三个供数方法各一次；两趟共用快照所以仍是 3。缓存失效就会涨到 6
  assert_eq(probe.calls, 3, msg="一次会话一轮取数")
}

///|
async test "MB4 权限不足 NotPermission、角色不足 NotRole，状态都是 403" {
  reset_probe(["sys:user:list"], ["user"], false)
  let auth = mb_auth("mb4")
  let token = auth.login("u1", device="pc").token
  assert_eq(
    fail_reason(auth, policy(), req("/sys/user/save", Some(token))),
    "no permission: sys:user:save",
  )
  assert_eq(@guard.status_of(@port.NotPermission("x")), 403)

  let role_pol = (@core_guard.RoutePolicy::new()).rule(
    @core_guard.RouteRule::make("/admin/panel", []).with_roles(["admin"], @port.And),
  )
  assert_eq(
    fail_reason(auth, role_pol, req("/admin/panel", Some(token))),
    "no role: admin",
  )
  assert_eq(@guard.status_of(@port.NotRole("x")), 403)
}

///|
async test "MB5 关掉推导后未覆盖的路径只验登录：给主体、不裁决权限" {
  reset_probe([], [], false)
  let auth = mb_auth("mb5")
  let token = auth.login("u1", device="pc").token
  let quiet = @core_guard.RoutePolicy::new()
  quiet.by_convention = false
  let subject = @guard.decide(auth, quiet, req("/anywhere", Some(token)))
  match subject {
    None => fail("已登录就该有主体")
    Some(p) => assert_eq(p.login_id, "u1")
  }
  assert_eq(
    fail_reason(auth, quiet, req("/anywhere", None)),
    "not login: AbsentToken",
  )
}

///|
async test "MB6 推导面按段推码（单码 AND）；推不出码的路径退成只验登录" {
  reset_probe(["api:orders:save"], [], false)
  let auth = mb_auth("mb6")
  let token = auth.login("u1", device="pc").token
  let derived = @core_guard.RoutePolicy::new()
  match @guard.decide(auth, derived, req("/api/orders/save", Some(token))) {
    None => fail("推出的 api:orders:save 在权限集里，应放行")
    Some(p) => assert_eq(p.login_id, "u1")
  }
  assert_eq(
    fail_reason(auth, derived, req("/api/orders/remove", Some(token))),
    "no permission: api:orders:remove",
  )
  // 含变量段的路径推不出码 ⇒ 只验登录，不替项目发明权限码
  assert_true(
    @guard.decide(auth, derived, req("/{module}/list", Some(token))) is Some(_),
  )
}

///|
async test "MB7 超管跳过裁决但仍要登录；关掉 super_bypass 后一视同仁" {
  reset_probe([], [], true)
  let auth = mb_auth("mb7")
  let pol = policy()
  let token = auth.login("boss", device="pc").token
  match @guard.decide(auth, pol, req("/sys/user/save", Some(token))) {
    None => fail("超管位为真时应放行")
    Some(p) => assert_true(p.super_admin, msg="主体要带上超管位给业务用")
  }
  assert_eq(
    fail_reason(auth, pol, req("/sys/user/save", None)),
    "not login: AbsentToken",
  )
  let off = @app.TokenConfig::default()
  off.super_bypass = false
  let strict = mb_auth_with("mb7s", off)
  let t2 = strict.login("boss", device="pc").token
  assert_eq(
    fail_reason(strict, pol, req("/sys/user/save", Some(t2))),
    "no permission: sys:user:save",
  )
}

///|
async test "MB8 注销后同一枚 token 立刻失效（快照跟着会话一起没）" {
  reset_probe(["sys:user:save"], [], false)
  let auth = mb_auth("mb8")
  let pol = policy()
  let token = auth.login("u1", device="pc").token
  assert_true(@guard.decide(auth, pol, req("/sys/user/save", Some(token))) is Some(_))
  auth.logout(token)
  assert_eq(
    fail_reason(auth, pol, req("/sys/user/save", Some(token))),
    "not login: UnknownToken",
  )
}

///|
async test "MB9 多码默认 AND、显式 Or 才放宽；伪造 token 归 401 不是 500" {
  reset_probe(["a:b"], [], false)
  let auth = mb_auth("mb9")
  let token = auth.login("u1", device="pc").token
  let and_pol = (@core_guard.RoutePolicy::new()).rule(
    @core_guard.RouteRule::make("/multi", ["a:b", "c:d"]),
  )
  let or_pol = (@core_guard.RoutePolicy::new()).rule(
    @core_guard.RouteRule::make("/multi", ["a:b", "c:d"]).with_perm_mode(@port.Or),
  )
  assert_eq(
    fail_reason(auth, and_pol, req("/multi", Some(token))),
    "no permission: c:d",
  )
  assert_true(@guard.decide(auth, or_pol, req("/multi", Some(token))) is Some(_))
  let forged = fail_reason(auth, or_pol, req("/multi", Some("z-not-a-token")))
  assert_eq(forged, "not login: UnknownToken")
  assert_eq(@guard.status_of(@port.NotLogin(@port.UnknownToken)), 401)
}
