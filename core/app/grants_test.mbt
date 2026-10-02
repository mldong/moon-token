///|
/// A31–A36：授权快照（`P:`）的三场景。
///
/// 为什么必须带计数探针：**只测"权限判得对"是测不出缓存的**——缓存彻底坏了判定照样对，
/// 只是每请求多问业务一次。所以这组用例的承重断言是"问了几次"，判定结果只是配角。
/// 探针放模块级 `let`（不是结构体字段）：MoonBit 里方法对 `self` 字段的改动是否回写调用方
/// 取决于传值语义，而共享可变单元不需要赌这一点——`auth_test.mbt` 的假时钟就是这么摆的。
struct GrantProbe {
  mut calls : Int
  mut perms : Array[String]
  mut roles : Array[String]
  mut super_admin : Bool
}

///|
let probe : GrantProbe = {
  calls: 0,
  perms: [],
  roles: [],
  super_admin: false,
}

///|
struct CountingPerms {}

///|
pub impl @port.PermissionProvider for CountingPerms with fn get_permissions(
  _self,
  _login_id,
  _device,
) {
  probe.calls += 1
  probe.perms
}

///|
pub impl @port.PermissionProvider for CountingPerms with fn get_roles(
  _self,
  _login_id,
  _device,
) {
  probe.calls += 1
  probe.roles
}

///|
pub impl @port.PermissionProvider for CountingPerms with fn is_super_admin(
  _self,
  _login_id,
  _device,
) {
  probe.calls += 1
  probe.super_admin
}

///|
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
fn grant_auth_with(
  config : @app.TokenConfig,
) -> @app.TokenAuth[@mem.MemoryStore, CountingPerms] {
  let p = CountingPerms::{}
  @app.TokenAuth::new(
    "grant",
    config,
    @mem.MemoryStore::new("grant"),
    p,
    @style.opaque_style(),
  )
}

///|
fn grant_auth() -> @app.TokenAuth[@mem.MemoryStore, CountingPerms] {
  grant_auth_with(@app.TokenConfig::default())
}

///|
async test "A31 一枚会话只问业务一次：三次判定共用同一份快照" {
  @port.set_clock(Some(fn() { 9_000_000L }))
  reset_probe(["user:info"], ["user"], false)
  let auth = grant_auth()
  let t = auth.login("u1", device="pc").token
  assert_true(auth.has_permission(t, ["user:info"]))
  assert_true(auth.has_role(t, ["user"]))
  assert_false(auth.has_permission(t, ["user:delete"]))
  // 三个供数方法各一次；再多判十次也不会涨
  assert_eq(probe.calls, 3)
  @port.set_clock(None)
}

///|
async test "A32 业务改数不会自己生效，invalidate_grants 才换快照" {
  @port.set_clock(Some(fn() { 9_100_000L }))
  reset_probe(["user:info"], [], false)
  let auth = grant_auth()
  let t = auth.login("u1", device="pc").token
  assert_true(auth.has_permission(t, ["user:info"]))
  // 模拟业务改了权限：老会话必须还看见旧数，这正是缓存的语义
  probe.perms = ["user:delete"]
  assert_true(auth.has_permission(t, ["user:info"]))
  assert_eq(probe.calls, 3)
  assert_eq(auth.invalidate_grants("u1"), 1)
  assert_false(auth.has_permission(t, ["user:info"]))
  assert_true(auth.has_permission(t, ["user:delete"]))
  assert_eq(probe.calls, 6)
  @port.set_clock(None)
}

///|
async test "A33 注销即作废快照：重新登录一定重新问业务" {
  @port.set_clock(Some(fn() { 9_200_000L }))
  reset_probe(["user:info"], [], false)
  let auth = grant_auth()
  let t = auth.login("u1", device="pc").token
  assert_true(auth.has_permission(t, ["user:info"]))
  assert_eq(probe.calls, 3)
  auth.logout(t)
  probe.perms = ["user:delete"]
  let t2 = auth.login("u1", device="pc").token
  assert_false(auth.has_permission(t2, ["user:info"]))
  assert_eq(probe.calls, 6)
  @port.set_clock(None)
}

///|
async test "A34 超管位由业务给并进快照；关掉 super_bypass 后一视同仁" {
  @port.set_clock(Some(fn() { 9_300_000L }))
  reset_probe([], [], true)
  let auth = grant_auth()
  let t = auth.login("boss", device="pc").token
  assert_true(auth.has_permission(t, ["sys:manage"]))
  assert_true(auth.has_role(t, ["any-role"]))
  let off = @app.TokenConfig::default()
  off.super_bypass = false
  let strict = grant_auth_with(off)
  let t2 = strict.login("boss", device="pc").token
  assert_false(strict.has_permission(t2, ["sys:manage"]))
  let loud = try {
    strict.check_permission(t2, ["sys:manage"])
    "没抛"
  } catch {
    err => err.message()
  }
  assert_eq(loud, "no permission: sys:manage")
  // 两个 auth 实例各自回填一次：探针是共享的，所以总数是 3+3
  assert_eq(probe.calls, 6)
  @port.set_clock(None)
}

///|
async test "A35 身份不成立就一次业务都不问：认证挡在取数前面" {
  reset_probe(["user:info"], [], false)
  let auth = grant_auth()
  let quiet = try {
    auth.authenticate("not-a-token") |> ignore
    "没抛"
  } catch {
    err => err.message()
  }
  assert_eq(quiet, "not login: UnknownToken")
  assert_eq(probe.calls, 0)
}

///|
test "A36 快照线格式原样往返，坏串读成 miss 而不是崩" {
  let record = @port.PermissionRecord::make(
    "u|1",
    ["a=b", "c;d", "e\\f", "中文权限", "g\nh"],
    ["r;1"],
    true,
    1_234L,
  )
  match @port.PermissionRecord::decode(record.encode()) {
    None => fail("往返不该丢数据")
    Some(g) => {
      assert_eq(g.login_id, "u|1")
      assert_eq(g.perms.length(), 5)
      assert_eq(g.perms[0], "a=b")
      assert_eq(g.perms[1], "c;d")
      assert_eq(g.perms[2], "e\\f")
      assert_eq(g.perms[3], "中文权限")
      assert_eq(g.perms[4], "g\nh")
      assert_eq(g.roles[0], "r;1")
      assert_true(g.super_admin)
      assert_eq(g.built_at, 1_234L)
    }
  }
  // 空集是常态（新用户没有任何权限码），必须原样回来
  let empty = @port.PermissionRecord::make("u2", [], [], false, 0L)
  match @port.PermissionRecord::decode(empty.encode()) {
    None => fail("空快照也该能往返")
    Some(g) => {
      assert_eq(g.perms.length(), 0)
      assert_eq(g.roles.length(), 0)
      assert_false(g.super_admin)
    }
  }
  // 认不出的形状 ⇒ None（调用方按 miss 处理，回头问业务）
  assert_true(@port.PermissionRecord::decode("login=x|perms=") is None)
  assert_true(@port.PermissionRecord::decode("v=1|login=") is None)
  assert_true(@port.PermissionRecord::decode("不是记录") is None)
}
