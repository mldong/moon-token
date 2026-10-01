///|
/// A 系列（A1–A20）：打在**应用层用例**上——async + 内存适配器 + 注入时钟。
/// 黑盒测试档（`*_test.mbt`）：只有它才吃 moon.pkg 里 `for "test"` 的 import
/// （白盒档的生成驱动找不到 `moonbitlang/async`，实测 `Error [4020]`），
/// 所以包内符号一律显式 `@app.` 限定，免 `test_unqualified_package` 警告。
/// 假权限端口 `FixedPerms` 同时是"第三方可实现这套 trait"的活证据。
struct FakeClock {
  mut ms : Int64
}

///|
let clock : FakeClock = { ms: 1_000_000L, }

///|
fn advance(ms : Int64) -> Unit {
  clock.ms += ms
}

///|
fn now_ms() -> Int64 {
  clock.ms
}

///|
struct FixedPerms {
  permissions : Array[String]
  roles : Array[String]
}

///|
pub impl @port.PermissionProvider for FixedPerms with fn get_permissions(
  self,
  _login_id,
  _device,
) {
  self.permissions
}

///|
pub impl @port.PermissionProvider for FixedPerms with fn get_roles(
  self,
  _login_id,
  _device,
) {
  self.roles
}

///|
pub extend FixedPerms with @port.PermissionProvider::{
  get_permissions,
  get_roles,
}

///|
fn new_auth(
  realm : String,
  config : @app.TokenConfig,
  granted : Array[String],
  roles : Array[String],
) -> @app.TokenAuth[@mem.MemoryStore, FixedPerms] {
  @port.set_clock(Some(fn() { now_ms() }))
  let p : FixedPerms = { permissions: granted, roles, }
  @app.TokenAuth::new(
    realm,
    config,
    @mem.MemoryStore::new(realm),
    p,
    @style.opaque_style(),
  )
}

///|
fn standard() -> @app.TokenAuth[@mem.MemoryStore, FixedPerms] {
  new_auth("user", @app.TokenConfig::default(), ["user:info", "user:list"], [
    "admin",
  ])
}

///|
/// 把错误读成一个整数：负向用例据此**精确**断言（只断言"报错了"不算数）
fn code_of(err : @port.TokenError) -> Int {
  match err {
    @port.NotLogin(reason) => reason.code()
    @port.NotPermission(_) => 100
    @port.NotRole(_) => 101
    @port.Disabled(_, _) => 102
    @port.InvalidInput(_) => 103
    @port.Store(_) => 104
  }
}

///|
async fn access_code(
  auth : @app.TokenAuth[@mem.MemoryStore, FixedPerms],
  token : String,
) -> Int {
  try {
    auth.check_login(token) |> ignore
    -1
  } catch {
    err => code_of(err)
  }
}

///|
fn str_or(value : String?, fallback : String) -> String {
  match value {
    None => fallback
    Some(v) => v
  }
}

///|
async test "A1 正向：login 后 check_login 拿回 login_id" {
  let auth = standard()
  let result = auth.login("u1", device="pc")
  assert_eq(result.login_id, "u1")
  assert_true(!result.reused)
  assert_true(!result.token.is_empty())
  assert_eq(auth.check_login(result.token), "u1")
}

///|
async test "A2 负向：空 token 报 AbsentToken" {
  let auth = standard()
  assert_eq(access_code(auth, ""), @port.AbsentToken.code())
  assert_eq(access_code(auth, "   "), @port.AbsentToken.code())
}

///|
async test "A3 负向：伪造 token 报 UnknownToken" {
  let auth = standard()
  auth.login("u1", device="pc") |> ignore
  assert_eq(access_code(auth, "not-a-real-token"), @port.UnknownToken.code())
}

///|
async test "A4 负向：过签发时效报 SessionExpired" {
  let auth = standard()
  let result = auth.login("u1", device="pc")
  advance(auth.config.timeout_ms() + 1L)
  assert_eq(access_code(auth, result.token), @port.SessionExpired.code())
}

///|
async test "A5 负向：被踢方拿到 KickedOut 而不是笼统未登录" {
  let auth = standard()
  let result = auth.login("u1", device="pc")
  assert_eq(auth.kickout("u1"), 1)
  assert_eq(access_code(auth, result.token), @port.KickedOut.code())
}

///|
async test "A6 负向：被顶方拿到 SupersededByLogin" {
  let auth = standard()
  let old = auth.login("u1", device="pc")
  assert_eq(auth.supersede("u1"), 1)
  assert_eq(access_code(auth, old.token), @port.SupersededByLogin.code())
}

///|
async test "A7 保留窗关上后不再报墓碑原因，而是 UnknownToken（状态不堆积）" {
  let auth = standard()
  let result = auth.login("u1", device="pc")
  auth.kickout("u1") |> ignore
  advance(auth.config.kick_grace_ms() + 1L)
  assert_eq(access_code(auth, result.token), @port.UnknownToken.code())
}

///|
async test "A8 封禁：报 Disabled，解禁与到期自动失效都恢复" {
  let auth = standard()
  let result = auth.login("u1", device="pc")
  auth.disable("u1", @port.Duration::from_minutes(10L), reason="违规")
  assert_eq(access_code(auth, result.token), 102)
  assert_true(auth.is_disabled("u1"))
  auth.undo_disable("u1")
  assert_true(!auth.is_disabled("u1"))
  assert_eq(access_code(auth, result.token), -1)
  auth.disable("u1", @port.Duration::from_minutes(5L))
  advance(6L * 60_000L)
  assert_true(!auth.is_disabled("u1"))
}

///|
async test "A9 多 realm 隔离：user 的 token 在 admin 实例下不认" {
  let user_auth = standard()
  let admin_auth = new_auth("admin", @app.TokenConfig::default(), [], [])
  let result = user_auth.login("u1", device="pc")
  assert_eq(access_code(admin_auth, result.token), @port.UnknownToken.code())
  assert_eq(user_auth.check_login(result.token), "u1")
}

///|
async test "A10 权限与角色：AND/OR 判定与缺失项报错" {
  let auth = standard()
  let result = auth.login("u1", device="pc")
  assert_true(auth.has_permission(result.token, ["user:info"]))
  assert_true(!auth.has_permission(result.token, ["user:info", "user:write"]))
  assert_true(
    auth.has_permission(
      result.token,
      ["user:write", "user:list"],
      mode=@port.Or,
    ),
  )
  let perm_code = try {
    auth.check_permission(result.token, ["user:write"])
    -1
  } catch {
    err => code_of(err)
  }
  assert_eq(perm_code, 100)
  assert_true(auth.has_role(result.token, ["admin"]))
  let role_code = try {
    auth.check_role(result.token, ["ops"])
    -1
  } catch {
    err => code_of(err)
  }
  assert_eq(role_code, 101)
}

///|
async test "A11 在线列表只列 Active 且未过期的会话" {
  let auth = standard()
  let a = auth.login("u1", device="pc")
  auth.login("u1", device="mobile") |> ignore
  assert_eq(auth.get_token_list_by_login_id("u1").length(), 2)
  auth.kickout("u1", device="mobile") |> ignore
  let after = auth.get_token_list_by_login_id("u1")
  assert_eq(after.length(), 1)
  assert_eq(after[0].token, a.token)
  let devices = auth.get_device_list("u1")
  assert_eq(devices, ["pc"])
}

///|
async test "A12 sweep 回收过期条目并返回条数（内存不泄漏）" {
  let auth = standard()
  auth.login("u1", device="pc") |> ignore
  assert_eq(auth.sweep(), 0)
  advance(auth.config.timeout_ms() + 1L)
  assert_true(auth.sweep() >= 1)
  assert_eq(auth.sweep(), 0)
}

///|
async test "A13 注销漏斗：T 键删 + 反查族摘除 + 绑定的 refresh 一并失效" {
  let auth = standard()
  let result = auth.login("u1", device="pc")
  auth.logout(result.token)
  assert_eq(access_code(auth, result.token), @port.UnknownToken.code())
  assert_eq(auth.get_token_list_by_login_id("u1").length(), 0)
  let rotate_code = try {
    auth.rotate(result.refresh_token) |> ignore
    -1
  } catch {
    err => code_of(err)
  }
  assert_eq(rotate_code, @port.RefreshInvalid.code())
}

///|
async test "A14 rotate 正向：整对换新，旧 access 立即失效" {
  let auth = standard()
  let first = auth.login("u1", device="pc")
  let second = auth.rotate(first.refresh_token)
  assert_true(second.token != first.token)
  assert_true(!second.refresh_token.is_empty())
  assert_eq(auth.check_login(second.token), "u1")
  assert_eq(access_code(auth, first.token), @port.UnknownToken.code())
}

///|
async test "A15 rotate 重放被拒，空串同样被拒" {
  let auth = standard()
  let first = auth.login("u1", device="pc")
  auth.rotate(first.refresh_token) |> ignore
  let replay = try {
    auth.rotate(first.refresh_token) |> ignore
    -1
  } catch {
    err => code_of(err)
  }
  assert_eq(replay, @port.RefreshInvalid.code())
  let empty = try {
    auth.rotate("") |> ignore
    -1
  } catch {
    err => code_of(err)
  }
  assert_eq(empty, @port.RefreshInvalid.code())
}

///|
async test "A16 rotate 不校验绑定 access 存活：access 自然过期后仍能续命" {
  let auth = standard()
  let first = auth.login("u1", device="pc")
  // 闲置到 access 自然过期（refresh 30d 远长于 access 6h）
  advance(auth.config.timeout_ms() + 1L)
  assert_eq(access_code(auth, first.token), @port.SessionExpired.code())
  let second = auth.rotate(first.refresh_token)
  assert_eq(auth.check_login(second.token), "u1")
}

///|
async test "A17 事件：事实点各发一次、落库后才发、listener 抛错不带崩主流程" {
  let auth = standard()
  let seen : Array[Int] = []
  // 第二个 listener 故意抛错：主流程结果不能因观察者而变
  auth.on_event(ev => seen.push(ev.event_type.code()))
  auth.on_event(_ev => raise @port.Store("listener 故意炸"))
  let result = auth.login("u1", device="pc")
  assert_eq(seen, [@event.LoggedIn.code()])
  auth.kickout("u1") |> ignore
  auth.disable("u1", @port.Duration::from_minutes(1L))
  auth.undo_disable("u1")
  let second = auth.login("u1", device="pc")
  assert_eq(auth.logout_by_id("u1"), 2)
  assert_true(seen.contains(@event.Kicked.code()))
  assert_true(seen.contains(@event.Disabled.code()))
  assert_true(seen.contains(@event.Enabled.code()))
  assert_true(seen.contains(@event.LoggedOut.code()))
  assert_eq(auth.listener_count(), 2)
  assert_eq(access_code(auth, result.token), @port.UnknownToken.code())
  assert_eq(access_code(auth, second.token), @port.UnknownToken.code())
}

///|
async test "A18 会话读写：账号级与令牌级属性回读一致，None 即删" {
  let auth = standard()
  let result = auth.login("u1", device="pc")
  auth.update_account_session("u1", "dept", Some("rd"))
  auth.update_token_session(result.token, "ip", Some("10.0.0.1"))
  match auth.get_account_session("u1") {
    None => fail("账号级会话没落住")
    Some(r) => assert_eq(str_or(r.attrs.get("dept"), ""), "rd")
  }
  match auth.get_token_session(result.token) {
    None => fail("令牌级会话没落住")
    Some(session) => assert_eq(str_or(session.extra("ip"), ""), "10.0.0.1")
  }
  auth.update_account_session("u1", "dept", None)
  match auth.get_account_session("u1") {
    None => ()
    Some(r) => assert_true(r.attrs.get("dept") is None)
  }
  let bad_key = try {
    auth.update_token_session(result.token, "", Some("x"))
    -1
  } catch {
    err => code_of(err)
  }
  assert_eq(bad_key, 103)
}

///|
async test "A19 熵源三态：同种子可复现、异种子不可预测、形状校验兜住" {
  let seed = b"0123456789abcdef0123456789abcdef"
  let a = @style.opaque_style_with_seed(seed)
  let b = @style.opaque_style_with_seed(seed)
  assert_eq((a.generate)(), (b.generate)())
  let c = @style.opaque_style_with_seed(b"fedcba9876543210fedcba9876543210")
  assert_true((a.generate)() != (c.generate)())
  let via_host = @style.opaque_style_with(fn() { seed })
  assert_true((via_host.verify_shape)((via_host.generate)()))
  assert_true(!(a.verify_shape)("short"))
  assert_true(!(a.verify_shape)((a.generate)() + "x"))
  // 默认档必须走平台熵：连续两次签发不同（wasm 档实测有熵；无熵档构造即 abort）
  let auth = standard()
  let one = auth.login("u1", device="pc")
  let two = auth.login("u1", device="mobile")
  assert_true(one.token != two.token)
}

///|
async test "A20 续期节流：窗内不写后端，出窗才把到期点往前推" {
  let auth = standard()
  let result = auth.login("u1", device="pc")
  let issued = result.expire_at
  auth.check_login(result.token) |> ignore
  match auth.get_token_session(result.token) {
    None => fail("会话不该消失")
    Some(session) => assert_eq(session.expire_at(), issued)
  }
  advance(auth.config.renew_min_interval_ms() + 1L)
  auth.check_login(result.token) |> ignore
  match auth.get_token_session(result.token) {
    None => fail("会话不该消失")
    Some(session) => assert_true(session.expire_at() > issued)
  }
}
