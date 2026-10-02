///|
/// 路由权限策略：**约定推导为默认，例外清单覆盖**。
///
/// 为什么放在 `guard` 而不是 `policy`：这里要复用同包内的 `matches_path`，
/// 而 `policy` 是被 `app` 依赖的下层、`app` 又是 `guard` 的依赖 ⇒ 放 `policy` 会成环。
/// `guard` 本来就是"面向 web 的编排层"（`run_guard` 在这儿调 `check_login`）。
///
/// 判定顺序：
///
/// ```text
/// ① exempt 命中          ⇒ Public     （连 token 都不看）
/// ② 例外清单命中         ⇒ Guarded    （按声明的 perms/roles 与各自 mode 校验）
/// ③ 未覆盖且 derive 开着 ⇒ Guarded    （从 path 推一个码，单码 AND）
/// ④ 其余                 ⇒ LoginOnly  （只验登录，不验权限）
/// ```
///
/// ② 在 ③ 之前：**例外优先于约定**。推导与实际要求不一致是常态而非错误——
/// 某个查询端点可能确实归在另一个权限码下（路径叫 `start`、要的是 `stop` 权限）。
/// 所以装载时不报错，只把"没吃推导的"列出来给人审（见 `exceptions`）。

///|
/// 一条路由的权限要求。`perms` 与 `roles` 都非空时是 **AND**（既要这个权限、也要这个角色），
/// 各自内部再按自己的 mode 判——对齐"两个注解同时打在一个方法上"的叠加语义。
pub(all) struct RouteRule {
  /// ant 风格路径：`/sys/user/save`、`/wf/**`、`/dev/schema/*`
  mut pattern : String
  mut perms : Array[String]
  mut perm_mode : @port.MatchMode
  /// 预留维度：多数框架用权限码做端点鉴权，角色只在少数场景用。
  /// 形状现在就定下来，免得将来真用时给同一个问题长出第二套机制。
  mut roles : Array[String]
  mut role_mode : @port.MatchMode
}

///|
pub fn RouteRule::make(
  pattern : String,
  perms : Array[String],
) -> RouteRule {
  let r : RouteRule = {
    pattern,
    perms,
    perm_mode: @port.And,
    roles: [],
    role_mode: @port.And,
  }
  r
}

///|
/// 多码时的组合方式。默认 **And**（安全侧）：漏写的后果只是让本该放行的用户吃 403，
/// 而默认 Or 的后果是越权。代价由 `unflagged_or` 在装载期提示兜住。
pub fn RouteRule::with_perm_mode(
  self : RouteRule,
  mode : @port.MatchMode,
) -> RouteRule {
  let r = self
  r.perm_mode = mode
  r
}

///|
pub fn RouteRule::with_roles(
  self : RouteRule,
  roles : Array[String],
  mode : @port.MatchMode,
) -> RouteRule {
  let r = self
  r.roles = roles
  r.role_mode = mode
  r
}

///|
pub(all) struct RoutePolicy {
  /// 公开面：命中即完全放行（各框架的"忽略鉴权"标记／白名单清单都落在这里）
  mut exempt : Array[String]
  /// 例外清单：优先于推导
  mut rules : Array[RouteRule]
  /// 关掉推导 ⇒ 未覆盖的端点一律只验登录。（`derive` 是 MoonBit 保留字，字段名只能绕）
  mut by_convention : Bool
  /// 推导规则本身。**本库不替任何项目定权限码长什么样**：默认那条是"段用 ':' 连"，
  /// 你自己的规范就换掉它（RESTful 风格、kebab-case、加模块前缀都行）。
  /// 返回 `None` 表示"这条路径推不出来"，调用方退成只验登录。
  mut deriver : (String) -> String?
}

///|
pub fn RoutePolicy::new() -> RoutePolicy {
  let p : RoutePolicy = {
    exempt: [],
    rules: [],
    by_convention: true,
    deriver: derive_perm,
  }
  p
}

///|
pub fn RoutePolicy::exempt(
  self : RoutePolicy,
  pattern : String,
) -> RoutePolicy {
  self.exempt.push(pattern)
  self
}

///|
pub fn RoutePolicy::rule(
  self : RoutePolicy,
  rule : RouteRule,
) -> RoutePolicy {
  self.rules.push(rule)
  self
}

///|
pub fn RoutePolicy::rule_count(self : RoutePolicy) -> Int {
  self.rules.length()
}

///|
fn join_colon(segs : Array[String]) -> String {
  let buf = StringBuilder()
  let mut first = true
  for s in segs {
    if !first {
      buf.write_string(":")
    }
    first = false
    buf.write_string(s)
  }
  buf.to_string()
}

///|
/// **默认**推导规则：`/api/orders/save` ⇒ `api:orders:save`，段用 `:` 连、空段丢弃。
/// 这只是开箱即用的默认值，不是本库给所有用户立的规矩——换规则见 `RoutePolicy::deriver`。
/// 含路径变量段（`{module}` 这种）时返回 `None`——推出来的码没有意义，
/// 这类端点必须走例外清单或豁免（框架里 `/{module}/{tableName}/export` 就是豁免的）。
pub fn derive_perm(path : String) -> String? {
  let out : Array[String] = []
  for seg in split_path(strip_head_slash(path)) {
    if seg.is_empty() {
      ()
    } else if seg.has_prefix("{") {
      return None
    } else {
      out.push(seg)
    }
  }
  if out.is_empty() {
    None
  } else {
    Some(join_colon(out))
  }
}

///|
pub(all) enum RouteAccess {
  /// 公开面：不验登录也不验权限
  Public
  /// 只验登录
  LoginOnly
  /// 验登录 + 这条规则
  Guarded(RouteRule)
}

///|
/// 规则具体度：**字面段多者优先**，再比变量段，最后按声明顺序。
/// 刻意不让"清单里的先后"变成语义——那是早晚要出事的隐式规则。
fn specificity(pattern : String) -> (Int, Int) {
  let mut literal = 0
  let mut variable = 0
  for seg in split_path(strip_head_slash(pattern)) {
    if seg == "*" || seg == "**" || seg.is_empty() {
      ()
    } else if seg.has_prefix("{") {
      variable += 1
    } else {
      literal += 1
    }
  }
  (literal, variable)
}

///|
/// 查例外清单：命中多条取最具体的；同具体度取先声明的（`>` 而非 `>=` 就是这个用处）。
fn RoutePolicy::find_rule(self : RoutePolicy, path : String) -> RouteRule? {
  let mut best : RouteRule? = None
  let mut best_literal = -1
  let mut best_variable = -1
  for rule in self.rules {
    if matches_path(rule.pattern, path) {
      let score = specificity(rule.pattern)
      if score.0 > best_literal || (score.0 == best_literal && score.1 > best_variable) {
        best = Some(rule)
        best_literal = score.0
        best_variable = score.1
      }
    }
  }
  best
}

///|
/// 纯判定：给 path，返回这次访问要验到哪一层。**零 IO**，可单测。
pub fn RoutePolicy::resolve(self : RoutePolicy, path : String) -> RouteAccess {
  let mut is_public = false
  for pattern in self.exempt {
    if matches_path(pattern, path) {
      is_public = true
    }
  }
  if is_public {
    Public
  } else {
    match self.find_rule(path) {
      Some(rule) => Guarded(rule)
      None =>
        if self.by_convention {
          match (self.deriver)(path) {
            Some(perm) => Guarded(RouteRule::make(path, [perm]))
            None => LoginOnly
          }
        } else {
          LoginOnly
        }
    }
  }
}

///|
/// 装载期审计辅助之一：列出"多码但没显式声明 mode"的条目。
/// 现实里多码八成是"任一即可"，而安全侧默认是 AND——这种条目要么真是要 AND，要么是忘了写 mode。
/// 给出来让人看一眼，比替他猜好。
pub fn RoutePolicy::unflagged_or(
  self : RoutePolicy,
  flagged : Array[String],
) -> Array[String] {
  self.rules
    .filter((r : RouteRule) => r.perms.length() > 1 && !flagged.contains(r.pattern))
    .map((r : RouteRule) => r.pattern)
}

///|
/// 装载期审计辅助之二：给定一批路径，返回"没吃推导"的那些（豁免／只验登录／换码／多码）。
pub fn RoutePolicy::exceptions(self : RoutePolicy, paths : Array[String]) -> Array[String] {
  paths.filter((path : String) => match self.resolve(path) {
    Public => true
    LoginOnly => true
    Guarded(rule) => {
      let derived = match (self.deriver)(path) {
        None => ""
        Some(v) => v
      }
      !(rule.perms.length() == 1 && rule.perms[0] == derived)
    }
  })
}

///|
/// 编排一次访问：登录永远先过（豁免除外），再按 `resolve` 的结果决定要不要查权限/角色。
/// 超管判定读 `P:` 快照里的 `super_admin`（数由业务在 `is_super_admin` 里给），开关是
/// `TokenConfig::super_bypass`。**调用方不再传 `is_super_admin`**：那是业务事实，
/// 库里既拿不到也不该每请求回业务库问一次。
/// 返回复用 `GuardOutcome`：豁免 ⇒ `Exempt`（没有主体），其余 ⇒ `Passed(login_id)`。
pub async fn[S : @port.TokenStore, P : @port.PermissionProvider] check_route(
  auth : @app.TokenAuth[S, P],
  route_policy : RoutePolicy,
  request : RequestFns,
) -> Result[GuardOutcome, @port.TokenError] {
  let path = (request.path)()
  let access = route_policy.resolve(path)
  match access {
    Public => Ok(Exempt)
    _ =>
      try {
        let token = extract_token(auth, request)
        let login_id = match access {
          Guarded(rule) =>
            auth.check_access(
              token,
              rule.perms,
              rule.perm_mode,
              rule.roles,
              rule.role_mode,
            )
          _ => auth.check_login(token)
        }
        Ok(Passed(login_id))
      } catch {
        err => Err(err)
      }
  }
}
