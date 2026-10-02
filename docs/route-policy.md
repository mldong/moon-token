# 路由权限策略

一句话：**默认按路径约定推权限码，例外走清单**。

这条设计的前提是"库不替项目立规矩"——推导规则本身是个可换的值（§5），默认那条只是
开箱即用。至于你自己的接口有多少条符合默认约定，那是你的选型依据，不是本库的契约，
所以这里不放任何具体项目的接口清单。

本页代码块由 `scripts/docs-check.sh` 逐块真编译真跑（对注册表已发布件）。

## 1. 判定顺序

```text
① exempt 命中          ⇒ Public      连 token 都不看
② 例外清单命中         ⇒ Guarded     按声明的 perms / roles 与各自 mode 校验
③ 未覆盖且推导开着     ⇒ Guarded     用 deriver 推一个码（单码 AND）
④ 其余                 ⇒ LoginOnly   只验登录，不验权限
```

**例外优先于约定**，而且"推导结果与你要的不一样"是常态不是错误——某个查询端点可能确实
归在另一个权限码下。这种就进例外清单，装载时库不报错，只把"没吃推导的"列出来给人审（§4）。

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
  let auth = view_auth(["api:orders:page"], [])
  let policy = @guard.RoutePolicy::new().exempt("/api/login")
  let t = auth.login("u1", device="pc").token
  [
    // ① 豁免：完全放行，且**没有主体**（返回 Exempt 而不是 Passed）
    code_of(@guard.check_route(auth, policy, req("/api/login", None), false)),
    // ③ 推导：/api/orders/page ⇒ api:orders:page，视图里有 ⇒ 放行
    code_of(@guard.check_route(
      auth,
      policy,
      req("/api/orders/page", Some(t)),
      false,
    )),
    // ③ 推出来的码查不到 ⇒ NotPermission（不是 NotLogin，前端据此决定要不要跳登录）
    code_of(@guard.check_route(
      auth,
      policy,
      req("/api/orders/save", Some(t)),
      false,
    )),
    // 保护端点不带 token ⇒ 登录先失败
    code_of(@guard.check_route(
      auth,
      policy,
      req("/api/orders/page", None),
      false,
    )),
  ]
}

async test "默认约定是主路：绝大多数端点不需要任何声明" {
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
  let auth = view_auth(["api:orders:lock"], [])
  let t = auth.login("u1", device="pc").token
  let policy = @guard.RoutePolicy::new()
    // 多码 OR：一个端点被"锁定/解锁"两个动作共用
    .rule(
      @guard.RouteRule::make(
        "/api/orders/lock",
        ["api:orders:lock", "api:orders:unlock"],
      ).with_perm_mode(@port.Or),
    )
    // 换码：路径叫 start，权限码却是 stop
    .rule(@guard.RouteRule::make("/api/jobs/start", ["api:jobs:stop"]))
  [
    code_of(@guard.check_route(
      auth,
      policy,
      req("/api/orders/lock", Some(t)),
      false,
    )),
    code_of(@guard.check_route(auth, policy, req("/api/jobs/start", Some(t)), false)),
    policy.rule_count(),
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

## 3. perms 与 roles 是同一张表的两列，不是两套机制

```moonbit
async fn perms_and_roles() -> Array[Int] raise {
  let policy = @guard.RoutePolicy::new().rule(
    @guard.RouteRule::make("/api/orders/page", ["api:orders:page"])
      .with_roles(["ops"], @port.And),
  )
  let only_perm = view_auth(["api:orders:page"], [])
  let t1 = only_perm.login("u1", device="pc").token
  let both = view_auth(["api:orders:page"], ["ops"])
  let t2 = both.login("u1", device="pc").token
  [
    code_of(@guard.check_route(
      only_perm,
      policy,
      req("/api/orders/page", Some(t1)),
      false,
    )),
    code_of(@guard.check_route(both, policy, req("/api/orders/page", Some(t2)), false)),
  ]
}

async test "perms 与 roles 同时存在是 AND" {
  let r = perms_and_roles()
  assert_eq(r[0], 101)
  assert_eq(r[1], -1)
}
```

`roles` 这一列很多项目今天用不上，但形状现在就定在这里——加两列，比将来给同一个问题
长出第二套机制再合并便宜得多。

多码的 `mode` 默认是 **And**：漏写时 And 只会让本该放行的人吃 403，而默认 Or 是越权。
后果要挑轻的那头，代价由 §4 那个装载提示兜住。

## 4. 装载期审计：把"需要人看一眼的"列出来

```moonbit
test "多码未标 mode、以及没吃推导的端点" {
  let policy = @guard.RoutePolicy::new()
    .rule(@guard.RouteRule::make("/a/b", ["x", "y"]).with_perm_mode(@port.Or))
    .rule(@guard.RouteRule::make("/a/c", ["x", "y"]))
  // 忘了写 mode 的多码条目：要么真是要 AND，要么是漏写
  assert_eq(policy.unflagged_or(["/a/b"]), ["/a/c"])
  // 没吃推导的端点清单（豁免／换码／多码／推不出码的都算）。
  // 注意 /error 不算例外——它推得出 "error" 这个码，只是大概不是你想要的。
  // 这类端点该进豁免清单，别指望推导失败替你兜住
  let e = policy.exceptions(["/api/orders/page", "/a/b", "/error"])
  assert_true(!e.contains("/api/orders/page"))
  assert_true(!e.contains("/error"))
  assert_true(e.contains("/a/b"))
}
```

## 5. 推导规则是可换的

默认规则是"路径段用 `:` 连"（`/api/orders/save` ⇒ `api:orders:save`）。如果你的项目另有
规范——RESTful 风格、kebab-case、要带模块前缀、`/users/{id}` 一律归到 `user:read`——
把 `deriver` 换成你自己的函数就行：不用改库，也不用把自己的规范塞进例外清单。

```text
let p = @guard.RoutePolicy::new()
p.deriver = fn(path) {
  if path.has_prefix("/users") {
    Some("user:read")
  } else if path.has_prefix("/orders") {
    Some("order:read")
  } else {
    None          // None ⇒ 这条推不出来，退成只验登录
  }
}
```

返回 `None` 表示"推不出来"，此时该端点退成 `LoginOnly`（只验登录、不验权限）。
**这是个要留意的降级**：如果你的规范里大量路径都推不出来，正确做法是换 `deriver`
或补例外清单，而不是让一堆端点静默停在"只验登录"——`exceptions()` 就是拿来发现这种漏的。

> 上面这段是 `text` 围栏而非可跑块：`deriver` 字段还没进注册表已发布件，写成 `moonbit`
> 会假红。发版后转成可跑块。（行为已经先被 `core/guard/policy_wbtest.mbt` 的 G5 钉住了。）

## 6. 为什么不是注解

同类框架常把权限码写在方法注解上。MoonBit 这条路走不通，也不需要走：

- 语言明确不支持运行时反射，注解只能被编译期工具消费。要"就地声明"就得配 codegen 工具
  + 构建钩子 + 生成物提交三件套。
- 而注解承载的就是这张表：`{path → perms, mode}`。**表定下来之后，"就地写"和"集中写"
  只是同一份数据的两种摆放**——摆放随时可换，运行时不用动。
- 约定成立的话，绝大多数端点连声明都不需要；剩下几条集中在一张清单里反而更好审。

配置文件读取消定在**应用侧**（本库不引 fs/json，保持端口零依赖）：把配置解析成
`RoutePolicy` 的值传进来即可。任何 web 框架的适配层要做的都只是
"取 token、取 path、把 `check_route` 的结果翻成 401/403 响应"。

## 7. 边界

- **库里没有用户模型**：`is_super_admin` 由业务传。"谁是超管"是业务事实，不是鉴权事实。
- **超管只免权限，未免登录**：没带 token 的"超管"照样过不了登录校验。
  `super_bypass = false` 时超管也要老实查权限（生产环境建议关掉）。
- **豁免面没有主体**：返回 `Exempt` 而不是 `Passed`。别在豁免路由上找 `login_id`——
  需要身份就别豁免它。
- **`check_route` 不做限流、不管请求体大小**：那是中间件层的事，混进来只会让权限这层说不清。
