# 路由权限策略

一句话：**`/sys/user/save` 默认就要 `sys:user:save`**，例外走清单。这条约定不是设计者偏好，
是从 mldong 框架 Java 基线仓全部 controller 扫出来的现状——199 个带鉴权声明的端点里
**171 个纯推导即等价**，剩下 28 个是 9 条豁免、17 条多码（全部 OR）、2 条换码。

本页代码块由 `scripts/docs-check.sh` 逐块真编译真跑（对注册表已发布件）。

## 1. 判定顺序

```text
① exempt 命中          ⇒ Public      连 token 都不看
② 例外清单命中         ⇒ Guarded     按声明的 perms / roles 与各自 mode 校验
③ 未覆盖且推导开着     ⇒ Guarded     从 path 推一个码（单码 AND）
④ 其余                 ⇒ LoginOnly   只验登录，不验权限
```

**例外优先于约定**，而且推导与声明不一致是常态不是错误——某个查询端点确实只在有
`wf:processTask:execute` 时用得到，这种换名是合法的。所以装载时不报错，
只把"没吃推导的"列出来给人审（见 §4）。

```moonbit
pub(all) struct View {
  permissions : Array[String]
  roles : Array[String]
}

pub impl @port.PermissionProvider for View with fn get_permissions(
  self,
  _login_id,
  _device,
) {
  self.permissions
}

pub impl @port.PermissionProvider for View with fn get_roles(
  self,
  _login_id,
  _device,
) {
  self.roles
}

pub extend View with @port.PermissionProvider::{get_permissions, get_roles}

fn view_auth(
  perms : Array[String],
  roles : Array[String],
) -> @app.TokenAuth[@mem.MemoryStore, View] {
  let p : View = { permissions: perms, roles, }
  @app.TokenAuth::new(
    "shop",
    @app.TokenConfig::default(),
    @mem.MemoryStore::new("shop"),
    p,
    @style.opaque_style(),
  )
}

fn req(path : String, token : String?) -> @guard.RequestFns {
  let fns : @guard.RequestFns = {
    path: fn() { path },
    header: fn(name) { if name == "Authorization" { token } else { None } },
  }
  fns
}

/// 把结果压成一个整数：-100 豁免、-1 放行、其余是错误码
fn code_of(v : Result[@guard.GuardOutcome, @port.TokenError]) -> Int {
  match v {
    Ok(@guard.Exempt) => -100
    Ok(@guard.Passed(_)) => -1
    Err(@port.NotPermission(_)) => 100
    Err(@port.NotRole(_)) => 101
    Err(@port.NotLogin(_)) => 401
    Err(_) => 900
  }
}

async fn by_convention() -> Array[Int] raise {
  let auth = view_auth(["sys:user:page"], [])
  let policy = @guard.RoutePolicy::new().exempt("/sys/login")
  let t = auth.login("u1", device="pc").token
  [
    // ① 豁免：完全放行，且**没有主体**（返回 Exempt 而不是 Passed）
    code_of(@guard.check_route(auth, policy, req("/sys/login", None), false)),
    // ③ 推导：/sys/user/page ⇒ sys:user:page，视图里有 ⇒ 放行
    code_of(@guard.check_route(
      auth,
      policy,
      req("/sys/user/page", Some(t)),
      false,
    )),
    // ③ 推导出的码查不到 ⇒ NotPermission（不是 NotLogin，前端据此决定要不要跳登录）
    code_of(@guard.check_route(
      auth,
      policy,
      req("/sys/user/save", Some(t)),
      false,
    )),
    // ④ 保护端点不带 token ⇒ 登录先失败
    code_of(@guard.check_route(
      auth,
      policy,
      req("/sys/user/page", None),
      false,
    )),
  ]
}

async test "约定推导是主路：171/199 的端点不需要任何声明" {
  let r = by_convention()
  assert_eq(r[0], -100)
  assert_eq(r[1], -1)
  assert_eq(r[2], 100)
  assert_eq(r[3], 401)
}
```

## 2. 例外清单

```moonbit
async fn overrides() -> Array[Int] raise {
  let auth = view_auth(["sys:user:locked"], [])
  let t = auth.login("u1", device="pc").token
  let policy = @guard.RoutePolicy::new()
    // 多码 OR：一个端点被"锁定/解锁"两个动作共用
    .rule(
      @guard.RouteRule::make(
        "/sys/user/locked",
        ["sys:user:locked", "sys:user:unLocked"],
      ).with_perm_mode(@port.Or),
    )
    // 换码：路径叫 start，权限码却是 stop（框架里真实存在，且是合法的）
    .rule(@guard.RouteRule::make("/sys/timer/start", ["sys:timer:stop"]))
  [
    code_of(@guard.check_route(
      auth,
      policy,
      req("/sys/user/locked", Some(t)),
      false,
    )),
    code_of(@guard.check_route(auth, policy, req("/sys/timer/start", Some(t)), false)),
    // 具体度：/sys/** 这条通配抢不过上面两条精确的
    (policy.rule_count()),
  ]
}

async test "例外清单优先于推导" {
  let r = overrides()
  assert_eq(r[0], -1)
  assert_eq(r[1], 100)
  assert_eq(r[2], 2)
}
```

多条规则同时命中时取**最具体的**（字面段多者优先，同分取先声明的）。
刻意不让"清单里的先后"变成语义——那是早晚要出事的隐式规则。

## 3. perms 与 roles 是同一维度的两列，不是两套机制

```moonbit
async fn perms_and_roles() -> Array[Int] raise {
  let policy = @guard.RoutePolicy::new().rule(
    @guard.RouteRule::make("/sys/user/page", ["sys:user:page"])
      .with_roles(["admin"], @port.And),
  )
  let only_perm = view_auth(["sys:user:page"], [])
  let t1 = only_perm.login("u1", device="pc").token
  let both = view_auth(["sys:user:page"], ["admin"])
  let t2 = both.login("u1", device="pc").token
  [
    code_of(@guard.check_route(
      only_perm,
      policy,
      req("/sys/user/page", Some(t1)),
      false,
    )),
    code_of(@guard.check_route(both, policy, req("/sys/user/page", Some(t2)), false)),
  ]
}

async test "perms 与 roles 同时存在是 AND" {
  let r = perms_and_roles()
  assert_eq(r[0], 101)
  assert_eq(r[1], -1)
}
```

`roles` 这一列在框架现状里**一个端点都没用**（199 个里 0 个，角色只出现在"超管直通"那条路上）。
仍然把形状定在这里，是为了将来真用时不再长出第二套机制——加两列比合并两套便宜得多。

多码的 `mode` 默认是 **And**，不是现状的 Or：漏写时 And 只会让本该放行的人吃 403，
而默认 Or 是越权。后果要挑轻的那头，代价由下面那个装载提示兜住。

## 4. 装载期审计：把"需要人看一眼的"列出来

```moonbit
test "多码未标 mode、以及没吃推导的端点" {
  let policy = @guard.RoutePolicy::new()
    .rule(
      @guard.RouteRule::make("/a/b", ["x", "y"]).with_perm_mode(@port.Or)
    )
    .rule(@guard.RouteRule::make("/a/c", ["x", "y"]))
  // 忘了写 mode 的多码条目——框架现状 17/17 都是 OR，这条要么真是要 AND，要么是漏写
  assert_eq(policy.unflagged_or(["/a/b"]), ["/a/c"])
  // 没吃推导的端点清单（豁免／换码／多码／推不出码的都算）。
  // 注意 /error 不算例外——它推得出 "error" 这个码，只是大概不是你想要的，
  // 这类"能推导但语义不对"的端点该进豁免清单，不是指望推导失败兜住
  let e = policy.exceptions([
    "/sys/user/page",
    "/a/b",
    "/error",
    "/{module}/{tableName}/export",
  ])
  assert_true(!e.contains("/sys/user/page"))
  assert_true(!e.contains("/error"))
  assert_true(e.contains("/a/b"))
  assert_true(e.contains("/{module}/{tableName}/export"))
}
```

## 5. 为什么不是注解

同类框架把权限码写在方法注解上（`@SaCheckPermission("sys:user:save")`）。MoonBit 这条路走不通，
也**不需要**走：

- 语言明确不支持运行时反射，注解只能被编译期工具消费（官方文档原话），要就地声明就得配
  codegen 工具 + 构建钩子 + 生成物提交三件套。
- 而注解承载的就是这张表——`{path → perms, mode}`。表定下来之后，"就地写"和"集中写"
  只是同一份数据的两种摆放。摆放随时可换，运行时不用动。
- 更关键的是这条约定本身就是 **171/199 的命中率**：绝大多数端点连声明都不需要，
  剩下 28 条集中在一张清单里反而比散在 28 个方法上更好审。

配置文件读取消定在**应用侧**（本库不引 fs/json，保持端口零依赖）：把配置解析成
`RoutePolicy` 的值传进来就行。任何 web 框架的适配层要做的都只是
"取 token、取 path、把 `check_route` 的结果翻成 401/403 响应"。

## 6. 边界

- **库里没有用户模型**：`is_super_admin` 由业务传。"谁是超管"是业务事实，不是鉴权事实。
- **超管只免权限，未免登录**：没带 token 的"超管"照样过不了 `check_login`。
  `super_bypass = false` 时超管也要老实查权限（生产环境建议关掉）。
- **豁免面没有主体**：返回 `Exempt` 而不是 `Passed`。别在豁免路由上找 `login_id`——
  需要身份就别豁免它。
- **含路径变量的端点推不出码**（`/{module}/{tableName}/export` 这种）：`derive_perm` 直接给 `None`，
  这类端点必须显式进豁免或清单，不会静默降级成"只验登录"还不告诉你。
