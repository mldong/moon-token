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

///|
async test "A21 正向：max_sessions 超限按登录时刻剔最老（默认 Logout 档）" {
  let cfg = @app.TokenConfig::default()
  cfg.max_sessions = 2
  let auth = new_auth("user", cfg, [], [])
  let first = auth.login("u1", device="d1")
  advance(1_000L)
  let second = auth.login("u1", device="d2")
  advance(1_000L)
  let third = auth.login("u1", device="d3")
  // 签第三枚时活成员 2+1>2 ⇒ 最早那枚被注销：读作 UnknownToken（当作没登录过）
  assert_eq(access_code(auth, first.token), @port.UnknownToken.code())
  assert_eq(access_code(auth, second.token), -1)
  assert_eq(access_code(auth, third.token), -1)
  assert_eq((auth.get_token_list_by_login_id("u1")).length(), 2)
}

///|
async test "A22 overflow_exit 三档：被剔方读到的原因各不相同" {
  let a = @app.TokenConfig::default()
  a.max_sessions = 1
  a.overflow_exit = @port.Logout
  let auth_a = new_auth("r1", a, [], [])
  let old_a = auth_a.login("u1", device="d1")
  advance(10L)
  auth_a.login("u1", device="d2") |> ignore
  assert_eq(access_code(auth_a, old_a.token), @port.UnknownToken.code())

  let b = @app.TokenConfig::default()
  b.max_sessions = 1
  b.overflow_exit = @port.Kick
  let auth_b = new_auth("r2", b, [], [])
  let old_b = auth_b.login("u1", device="d1")
  advance(10L)
  auth_b.login("u1", device="d2") |> ignore
  assert_eq(access_code(auth_b, old_b.token), @port.KickedOut.code())

  let c = @app.TokenConfig::default()
  c.max_sessions = 1
  c.overflow_exit = @port.Supersede
  let auth_c = new_auth("r3", c, [], [])
  let old_c = auth_c.login("u1", device="d1")
  advance(10L)
  auth_c.login("u1", device="d2") |> ignore
  assert_eq(access_code(auth_c, old_c.token), @port.SupersededByLogin.code())
}

///|
async test "A23 回归：Shared 复用同 token 不新增成员，故不触发上限；跨设备仍受上限" {
  let cfg = @app.TokenConfig::default()
  cfg.concurrent = @port.Shared
  cfg.max_sessions = 2
  let auth = new_auth("user", cfg, [], [])
  let one = auth.login("u1", device="d1")
  let again = auth.login("u1", device="d1")
  assert_eq(one.token, again.token)
  assert_true(again.reused)
  assert_eq((auth.get_token_list_by_login_id("u1")).length(), 1)
  advance(10L)
  auth.login("u1", device="d2") |> ignore
  advance(10L)
  let third = auth.login("u1", device="d3")
  // 现在才真的超限（d1 那枚最老）
  assert_eq(access_code(auth, one.token), @port.UnknownToken.code())
  assert_eq(access_code(auth, third.token), -1)
}

///|
async test "A24 族成员带登录时刻；旧串缺 lt 解出 0 而不是整条拒读" {
  let fam = @domain.AccountFamily::empty("u1")
  fam.add_member(@port.Device::of("pc"), "t-1", 9_000L, 1_500L) |> ignore
  // 线格式字段名是契约：成员条目里必须带键 `lt`。载荷套了两层转义，
  // 所以逐层解开比断言字面量稳（比 `"lt=1500"` 会因转义假红，比数反斜杠更难读）
  let outer = match @port.decode_record(fam.payload()) {
    None => fail("族载荷解不开")
    Some(map) => map
  }
  let rows = @port.decode_list(str_or(outer.get("members"), ""))
  assert_eq(rows.length(), 1)
  let row = match @port.decode_record(rows[0]) {
    None => fail("成员条目解不开")
    Some(map) => map
  }
  assert_eq(@port.record_field_or(row, "lt", ""), "1500")
  match @domain.AccountFamily::parse("u1", fam.payload()) {
    None => fail("族记录往返失败")
    Some(copy) => assert_eq((copy.members())[0].login_time, 1_500L)
  }
  // 手工造一条升级前的旧串（成员里没有 lt）：必须还能解，缺的字段走默认值
  let legacy_member = @port.encode_record([
    ("d", "pc"),
    ("t", "t-1"),
    ("e", "9000"),
  ])
  let legacy = @port.encode_record([
    ("login", "u1"),
    ("ver", "1"),
    ("members", @port.encode_list([legacy_member])),
  ])
  match @domain.AccountFamily::parse("u1", legacy) {
    None => fail("旧串应能解出，不能因为多个新字段就把整条族拒掉")
    Some(old) => assert_eq((old.members())[0].login_time, 0L)
  }
}

///|
async test "A25 在线枚举：登录时刻反序 + 游标翻页不重不漏 + 条件过滤" {
  let auth = standard()
  let t1 = auth.login("u1", device="pc")
  advance(10L)
  let t2 = auth.login("u2", device="pc")
  advance(10L)
  let t3 = auth.login("u1", device="pad")
  let page = auth.list_online(@port.SessionFilter::all(), "", 2)
  assert_eq(page.items.length(), 2)
  assert_eq((page.items)[0].token, t3.token)
  assert_eq((page.items)[1].token, t2.token)
  assert_true(!(page.next_cursor).is_empty())
  let page2 = auth.list_online(@port.SessionFilter::all(), page.next_cursor, 2)
  assert_eq(page2.items.length(), 1)
  assert_eq((page2.items)[0].token, t1.token)
  assert_eq(page2.next_cursor, "")
  // 精确条件：只看 u1
  let only = auth.list_online(@port.SessionFilter::make("u1", ""), "", 10)
  assert_eq(only.items.length(), 2)
  for item in only.items {
    assert_eq(item.login_id, "u1")
  }
  // 详情批量取：顺序一致且都能读到
  let rows = auth.load_online(page)
  assert_eq(rows.length(), 2)
  for row in rows {
    match row.session {
      None => fail("三条刚签的会话不该读不到")
      Some(record) => assert_true(!(record.login_id).is_empty())
    }
  }
}

///|
async test "A26 索引落后于事实时：load_online 交回 None，不返回错数据" {
  let auth = standard()
  auth.login("u1", device="pc") |> ignore
  let stale = @port.SessionPage::make(
    [@port.SessionListing::make("no-such-token", "u1", "pc", 1L, 9_000L)],
    "",
  )
  let rows = auth.load_online(stale)
  assert_eq(rows.length(), 1)
  assert_true((rows[0].session) is None)
}

///|
async test "A27 回归：账号会话每次写推版本；族空后 TTL 有下限不再永不过期" {
  let auth = standard()
  let login = auth.login("u1", device="pc")
  auth.update_account_session("u1", "theme", Some("dark"))
  match auth.get_account_session("u1") {
    None => fail("刚写完就读不到")
    Some(r) => assert_eq(r.version, 1L)
  }
  auth.update_account_session("u1", "theme", Some("light"))
  match auth.get_account_session("u1") {
    None => fail("第二次写读不到")
    Some(r) => assert_eq(r.version, 2L)
  }
  // 注销干净 ⇒ 族空 ⇒ 旧公式 max_expire()=0＝永不过期，这条键会永远漏在库里
  auth.logout(login.token)
  auth.update_account_session("u1", "lang", Some("zh"))
  advance(31L * 24L * 3600L * 1000L)
  assert_true(auth.get_account_session("u1") is None)
}

///|
async test "A28 封禁记录带操作人与创建时刻" {
  let auth = standard()
  auth.disable(
    "u1",
    @port.Duration::from_millis(60_000L),
    reason="违规",
    operator="admin-7",
  )
  match auth.ban_of("u1") {
    None => fail("应读到封禁")
    Some(ban) => {
      assert_eq(ban.operator, "admin-7")
      assert_eq(ban.created_at, now_ms())
      assert_eq(ban.reason, "违规")
    }
  }
  // 不传操作人的老写法仍要能编译并解出空串（向后兼容）
  auth.disable("u2", @port.Duration::from_millis(60_000L))
  match auth.ban_of("u2") {
    None => fail("u2 应被封禁")
    Some(ban) => assert_eq(ban.operator, "")
  }
}

///|
async test "A29 回归：显式 sweep 之后，刚过时效的会话仍报 SessionExpired 而不是 UnknownToken" {
  let cfg = @app.TokenConfig::default()
  cfg.timeout = @port.Duration::from_millis(1_000L)
  cfg.kick_grace = @port.Duration::from_millis(5_000L)
  let auth = new_auth("user", cfg, [], [])
  let login = auth.login("u1", device="pc")
  advance(2_000L)
  // 过时效但仍在保留窗内：`T:` 键的 TTL 含保留窗，所以 sweep 不该把它连键删掉
  auth.sweep() |> ignore
  assert_eq(access_code(auth, login.token), @port.SessionExpired.code())
}

///|
async test "A30 Shared 复用同 token 会刷新登录序：上限剔的是久没复登的那台" {
  let cfg = @app.TokenConfig::default()
  cfg.concurrent = @port.Shared
  cfg.max_sessions = 2
  let auth = new_auth("user", cfg, [], [])
  let old = auth.login("u1", device="d1")
  advance(10L)
  let mid = auth.login("u1", device="d2")
  advance(10L)
  // d1 天天复登：复用同一枚 token，但登录序必须回到队尾
  let again = auth.login("u1", device="d1")
  assert_eq(again.token, old.token)
  assert_true(again.reused)
  advance(10L)
  let third = auth.login("u1", device="d3")
  // 2 个活成员 + 新签 1 > 2 ⇒ 剔最老的：是久没动静的 d2，不是天天复登的 d1
  assert_eq(access_code(auth, mid.token), @port.UnknownToken.code())
  assert_eq(access_code(auth, again.token), -1)
  assert_eq(access_code(auth, third.token), -1)
}
