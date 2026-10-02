///|
/// G1/G2：守卫是纯逻辑——路径匹配（同步）与"保护面 + 豁免 + 追加断言"的端到端各测一条。
struct FixedView {
  permissions : Array[String]
  roles : Array[String]
  super_admin : Bool
}

///|
pub impl @port.PermissionProvider for FixedView with fn get_permissions(
  self,
  _login_id,
  _device,
) {
  self.permissions
}

///|
pub impl @port.PermissionProvider for FixedView with fn get_roles(
  self,
  _login_id,
  _device,
) {
  self.roles
}

///|
pub impl @port.PermissionProvider for FixedView with fn is_super_admin(
  self,
  _login_id,
  _device,
) {
  self.super_admin
}

///|
pub extend FixedView with @port.PermissionProvider::{
  get_permissions,
  get_roles,
  is_super_admin,
}

///|
fn request(path : String, token : String?) -> @guard.RequestFns {
  let fns : @guard.RequestFns = {
    path: fn() { path },
    header: fn(name) { if name == "Authorization" { token } else { None } },
  }
  fns
}

///|
test "G1 路径模式：/** 吃尾段、* 名单段、字面相等" {
  assert_true(@guard.matches_path("/api/**", "/api/user/list"))
  assert_true(@guard.matches_path("/api/**", "/api/user"))
  assert_true(!@guard.matches_path("/api/**", "/login"))
  assert_true(@guard.matches_path("/api/*", "/api/user"))
  assert_true(!@guard.matches_path("/api/*", "/api/user/list"))
  assert_true(@guard.matches_path("/api/login", "/api/login"))
}

///|
async test "G2 端到端：公开端点放行、保护端点未登录拦下、带 token 放行并跑追加断言" {
  @port.set_clock(Some(fn() { 5_000_000L }))
  let store = @mem.MemoryStore::new("user")
  let p : FixedView = {
    permissions: ["user:info"],
    roles: [],
    super_admin: false,
  }
  let auth = @app.TokenAuth::new(
    "user",
    @app.TokenConfig::default(),
    store,
    p,
    @style.opaque_style(),
  )
  let result = auth.login("u1", device="pc")
  let base = @guard.RouteGuard::new()
    .match_pattern("/api/**")
    .not_match_pattern("/api/login")
  // 公开端点：不在保护面 ⇒ 放行，且**不给主体**（给了就是假 login_id）
  let public_pass = @guard.run_guard(auth, base, request("/api/login", None))
  match public_pass {
    Ok(@guard.Exempt) => assert_true(true)
    Ok(@guard.Passed(id)) => fail("豁免端点不该产出主体，实得 " + id)
    Err(err) => fail("豁免端点不该被拦，实得 " + err.message())
  }
  // 保护端点 + 无 token ⇒ 必须拦下，且报的是 AbsentToken
  let blocked = @guard.run_guard(auth, base, request("/api/user/list", None))
  match blocked {
    Ok(_) => fail("无 token 访问保护端点必须被拦下")
    Err(err) => {
      let reason = match err.not_login_reason() {
        None => @port.UnknownToken
        Some(r) => r
      }
      assert_eq(reason.code(), @port.AbsentToken.code())
    }
  }
  // 带 token ⇒ 放行并返回 login_id
  match
    @guard.run_guard(auth, base, request("/api/user/list", Some(result.token))) {
    Ok(@guard.Passed(login_id)) => assert_eq(login_id, "u1")
    Ok(@guard.Exempt) => fail("保护端点不该走成豁免")
    Err(err) => fail("带有效 token 应当放行，实得 " + err.message())
  }
  // 追加断言确实被执行到了
  let seen : Array[String] = []
  let strict = base.check((login_id, _token) => seen.push(login_id))
  @guard.run_guard(auth, strict, request("/api/user/list", Some(result.token)))
  |> ignore
  assert_eq(seen, ["u1"])
  @port.set_clock(None)
}

///|
/// R1：README「最小用法」那段要真能编译并跑通核心链（文档示例抽出来真跑的既有纪律）。
/// 挂在 guard 包的测试里：README 的示例本身就是"auth + 守卫"这条组合。
async test "R1 README 最小用法跑通 login → check → kick 精确原因 + 守卫拦截" {
  @port.set_clock(Some(fn() { 9_000_000L }))
  let store = @mem.MemoryStore::new("user")
  let p : FixedView = {
    permissions: ["user:info"],
    roles: ["admin"],
    super_admin: false,
  }
  let auth = @app.TokenAuth::new(
    "user",
    @app.TokenConfig::default(),
    store,
    p,
    @style.opaque_style(),
  )
  let result = auth.login("u1", device="pc")
  assert_eq(auth.check_login(result.token), "u1")
  auth.kickout("u1", device="pc") |> ignore
  let code = try {
    auth.check_login(result.token) |> ignore
    -1
  } catch {
    err =>
      match err.not_login_reason() {
        None => -2
        Some(r) => r.code()
      }
  }
  assert_eq(code, @port.KickedOut.code())
  let route_guard = @guard.RouteGuard::new()
    .match_pattern("/api/**")
    .not_match_pattern("/api/public/**")
  assert_true(
    @guard.run_guard(auth, route_guard, request("/api/user/info", None))
    is Err(_),
  )
  let public_pass2 = @guard.run_guard(
    auth,
    route_guard,
    request("/api/public/ping", None),
  )
  match public_pass2 {
    Ok(@guard.Exempt) => assert_true(true)
    Ok(@guard.Passed(id)) => fail("豁免前缀不该产出主体，实得 " + id)
    Err(err) => fail("豁免前缀不该被拦，实得 " + err.message())
  }
  @port.set_clock(None)
}

///|
/// G7–G10：`check_route` 的编排语义（登录/权限/角色/超管四件事各钉一条）。
fn view_auth(
  perms : Array[String],
  roles : Array[String],
) -> @app.TokenAuth[@mem.MemoryStore, FixedView] {
  view_auth_with(perms, roles, false, @app.TokenConfig::default())
}

///|
fn view_auth_with(
  perms : Array[String],
  roles : Array[String],
  super_admin : Bool,
  config : @app.TokenConfig,
) -> @app.TokenAuth[@mem.MemoryStore, FixedView] {
  let p : FixedView = { permissions: perms, roles, super_admin, }
  @app.TokenAuth::new(
    "route",
    config,
    @mem.MemoryStore::new("route"),
    p,
    @style.opaque_style(),
  )
}

fn err_code(v : Result[@guard.GuardOutcome, @port.TokenError]) -> Int {
  match v {
    Ok(@guard.Exempt) => -100
    Ok(@guard.Passed(_)) => -1
    Err(@port.NotLogin(reason)) => reason.code()
    Err(@port.NotPermission(_)) => 100
    Err(@port.NotRole(_)) => 101
    Err(_) => 900
  }
}

async test "G7 豁免给 Exempt（没有主体），有权端点给 Passed，无权端点报 NotPermission" {
  let auth = view_auth(["api:orders:page"], [])
  let policy = @guard.RoutePolicy::new().exempt("/api/login")
  let t = auth.login("u1", device="pc").token
  let r0 = @guard.check_route(auth, policy, request("/api/login", None))
  assert_true(r0 is Ok(@guard.Exempt))
  // 没配任何规则 ⇒ 走推导：/api/orders/page ⇒ api:orders:page，视图里有这个码 ⇒ 放行
  let r1 = @guard.check_route(auth, policy, request("/api/orders/page", Some(t)))
  match r1 {
    Ok(@guard.Passed(id)) => assert_eq(id, "u1")
    _ => assert_eq(err_code(r1), -1)
  }
  // 换一个视图里没有的端点 ⇒ 推导出的码查不到 ⇒ NotPermission（不是 NotLogin）
  let r2 = @guard.check_route(auth, policy, request("/api/orders/save", Some(t)))
  assert_eq(err_code(r2), 100)
  // 保护端点不带 token ⇒ 登录先失败，报的是 NotLogin 族而不是权限
  let no_token = @guard.check_route(auth, policy, request("/api/orders/page", None))
  assert_true(err_code(no_token) >= 0)
}

async test "G8 超管位来自快照：跳过权限但仍要登录；关掉 super_bypass 后老实查权限" {
  let auth = view_auth([], [])
  let policy = @guard.RoutePolicy::new()
  // 普通用户拿不到这次放行：超管位由业务的 is_super_admin 给，库里不猜
  let t = auth.login("u1", device="pc").token
  let guest = @guard.check_route(auth, policy, request("/api/orders/save", Some(t)))
  assert_eq(err_code(guest), 100)
  let boss = view_auth_with([], [], true, @app.TokenConfig::default())
  let t2 = boss.login("u1", device="pc").token
  let admin = @guard.check_route(boss, policy, request("/api/orders/save", Some(t2)))
  assert_eq(err_code(admin), -1)
  // 没 token 的"超管"照样过不了登录：超管只免权限，未免登录
  let admin_nologin = @guard.check_route(
    boss,
    policy,
    request("/api/orders/save", None),
  )
  assert_true(admin_nologin is Err(_))
  let strict = @app.TokenConfig::default()
  strict.super_bypass = false
  let quiet = view_auth_with([], [], true, strict)
  let t3 = quiet.login("u1", device="pc").token
  let strict_admin = @guard.check_route(
    quiet,
    policy,
    request("/api/orders/save", Some(t3)),
  )
  assert_eq(err_code(strict_admin), 100)
}

async test "G9 perms 与 roles 同时存在是 AND：只有权限没角色照样拦" {
  let auth = view_auth(["api:orders:page"], [])
  let policy = @guard.RoutePolicy::new().rule(
    @guard.RouteRule::make("/api/orders/page", ["api:orders:page"])
      .with_roles(["ops"], @port.And),
  )
  let t = auth.login("u1", device="pc").token
  assert_eq(err_code(@guard.check_route(auth, policy, request("/api/orders/page", Some(t)))), 101)
  let both = view_auth(["api:orders:page"], ["ops"])
  let t2 = both.login("u1", device="pc").token
  assert_eq(
    err_code(@guard.check_route(both, policy, request("/api/orders/page", Some(t2)))),
    -1,
  )
}

async test "G10 Or 模式：多码有任一即放行，And 模式要求全有" {
  let auth = view_auth(["api:orders:lock"], [])
  let t = auth.login("u1", device="pc").token
  let or_policy = @guard.RoutePolicy::new().rule(
    @guard.RouteRule::make(
      "/api/orders/lock",
      ["api:orders:lock", "api:orders:unlock"],
    ).with_perm_mode(@port.Or),
  )
  assert_eq(
    err_code(@guard.check_route(auth, or_policy, request("/api/orders/lock", Some(t)))),
    -1,
  )
  let and_policy = @guard.RoutePolicy::new().rule(
    @guard.RouteRule::make(
      "/api/orders/lock",
      ["api:orders:lock", "api:orders:unlock"],
    ),
  )
  assert_eq(
    err_code(@guard.check_route(auth, and_policy, request("/api/orders/lock", Some(t)))),
    100,
  )
}
