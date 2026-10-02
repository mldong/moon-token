///|
/// G 系列（白盒、纯同步）：路由权限策略的判定规则。
///
/// 这里**不放任何来自具体项目的接口清单**——本库要钉的是规则本身
/// （豁免优先、例外优先于推导、具体度怎么比、推导规则可换）。
/// 某个项目的端点有多少条符合默认约定，那是那个项目自己的选型依据，不是这里的契约。

test "G1 默认推导：段用冒号连，变量段与空路径不推" {
  assert_eq(derive_perm("/api/orders/save"), Some("api:orders:save"))
  assert_eq(derive_perm("/api/orders/page"), Some("api:orders:page"))
  assert_eq(derive_perm("//api//orders//page"), Some("api:orders:page"))
  assert_eq(derive_perm("/"), None)
  assert_eq(derive_perm("/{module}/{tableName}/export"), None)
}

test "G2 判定顺序：豁免 > 例外清单 > 推导 > 只验登录" {
  let p = RoutePolicy::new()
    .exempt("/api/login")
    .rule(RouteRule::make("/api/logs/detail", ["a", "b"]).with_perm_mode(@port.Or))
  assert_true(p.resolve("/api/login") is Public)
  // 例外优先：推导本会给 api:logs:detail，但清单说了算
  match p.resolve("/api/logs/detail") {
    Guarded(r) => {
      assert_eq(r.perms.length(), 2)
      assert_true(r.perm_mode is @port.Or)
    }
    _ => fail("例外清单没生效")
  }
  match p.resolve("/api/orders/page") {
    Guarded(r) => assert_eq(r.perms[0], "api:orders:page")
    _ => fail("推导兜底没生效")
  }
  // 关掉推导 ⇒ 未覆盖的一律只验登录
  let off = RoutePolicy::new()
  off.by_convention = false
  assert_true(off.resolve("/api/orders/page") is LoginOnly)
  // 变量段推不出来 ⇒ 也只能只验登录（逼人去覆盖表或豁免）
  assert_true(p.resolve("/{module}/x/export") is LoginOnly)
}

test "G3 具体度：字面段多的赢，不吃清单顺序" {
  // 故意先声明通配、后声明精确——顺序反过来也必须命中精确那条
  let p = RoutePolicy::new()
    .rule(RouteRule::make("/api/**", ["broad"]))
    .rule(RouteRule::make("/api/orders/page", ["precise"]))
  match p.resolve("/api/orders/page") {
    Guarded(r) => assert_eq(r.perms[0], "precise")
    _ => fail("最具体的规则没赢")
  }
  // 同具体度取先声明的（稳定序，不让顺序变成隐式语义）
  let q = RoutePolicy::new()
    .rule(RouteRule::make("/api/orders/*", ["first"]))
    .rule(RouteRule::make("/api/orders/*", ["second"]))
  match q.resolve("/api/orders/page") {
    Guarded(r) => assert_eq(r.perms[0], "first")
    _ => fail("同具体度没取先声明的")
  }
}

test "G4 装载期审计辅助：多码未标 mode、以及没吃推导的清单" {
  let p = RoutePolicy::new()
    .rule(RouteRule::make("/a/b", ["x", "y"]).with_perm_mode(@port.Or))
    .rule(RouteRule::make("/a/c", ["x", "y"]))
  assert_eq(p.unflagged_or(["/a/b"]), ["/a/c"])
  // /error 不算例外——它推得出 "error"，只是大概不是你想要的；
  // 这类端点该进豁免清单，别指望推导失败替你兜住
  let e = p.exceptions(["/api/orders/page", "/a/b", "/error"])
  assert_true(!e.contains("/api/orders/page"))
  assert_true(!e.contains("/error"))
  assert_true(e.contains("/a/b"))
}

///|
/// G5 是本库"不替项目立规矩"的正面证据：换一个 deriver，整套判定跟着变，
/// 不用改库、也不用把自己的规范塞进例外清单。
test "G5 推导规则可换：RESTful 风格自己定" {
  // 某项目的规范是 /users/{id} 一律归到 user:read，与默认"段用冒号连"完全不同
  let restful = RoutePolicy::new()
  restful.deriver = fn(path) {
    if path.has_prefix("/users") {
      Some("user:read")
    } else if path.has_prefix("/orders") {
      Some("order:read")
    } else {
      None
    }
  }
  match restful.resolve("/users/42") {
    Guarded(r) => assert_eq(r.perms, ["user:read"])
    _ => fail("自定义推导没生效")
  }
  match restful.resolve("/orders") {
    Guarded(r) => assert_eq(r.perms, ["order:read"])
    _ => fail("自定义推导没生效")
  }
  assert_true(restful.resolve("/health") is LoginOnly)
  // 默认那条还在：换个实例不受影响，deriver 是值不是全局开关
  match RoutePolicy::new().resolve("/users/42") {
    Guarded(r) => assert_eq(r.perms, ["users:42"])
    _ => fail("默认推导被改坏了")
  }
}
