///|
/// 路由守卫 DSL：纯逻辑（路径模式 + 断言闭包链），**不依赖任何 web 框架**。
/// 请求侧的信息由调用方用 `RequestFns` 两个闭包供给（取路径、取头），
/// 所以 moonasgi/mooncat/`@http.Server` 都能在同一套守卫上挂（examples 示范后者）。

///|
pub(all) enum SegmentPattern {
  Literal
  AnySegment
  Tail
}

///|
pub(all) struct RequestFns {
  path : () -> String
  header : (String) -> String?
}

///|
pub(all) struct GuardRule {
  pattern : String
  except : Bool
}

///|
/// 断言闭包：拿到 login_id 之后还要不要再查权限，由调用方决定（check_permission 等）
pub(all) struct GuardCheck {
  run : (String, String) -> Unit raise @port.TokenError
}

///|
pub(all) struct RouteGuard {
  mut rules : Array[GuardRule]
  mut checks : Array[GuardCheck]
}

///|
pub fn RouteGuard::new() -> RouteGuard {
  let g : RouteGuard = { rules: [], checks: [], }
  g
}

///|
pub fn RouteGuard::match_pattern(
  self : RouteGuard,
  pattern : String,
) -> RouteGuard {
  let rule : GuardRule = { pattern, except: false, }
  self.rules.push(rule)
  self
}

///|
/// 例外（先匹配后豁免）：`/api/login` 这类公开端点靠它放行
pub fn RouteGuard::not_match_pattern(
  self : RouteGuard,
  pattern : String,
) -> RouteGuard {
  let rule : GuardRule = { pattern, except: true, }
  self.rules.push(rule)
  self
}

///|
pub fn RouteGuard::check(
  self : RouteGuard,
  run : (String, String) -> Unit raise @port.TokenError,
) -> RouteGuard {
  let item : GuardCheck = { run, }
  self.checks.push(item)
  self
}

///|
pub fn RouteGuard::rule_count(self : RouteGuard) -> Int {
  self.rules.length()
}

///|
/// 路径模式匹配：支持 `/**` 结尾（吃掉后续所有段）、`*`（单段任意）、以及字面相等。
fn segment_match(pattern : String, segment : String) -> Bool {
  if pattern == "*" {
    true
  } else {
    pattern == segment
  }
}

///|
pub fn matches_path(pattern : String, path : String) -> Bool {
  let pattern_parts = split_path(strip_head_slash(pattern))
  let path_parts = split_path(strip_head_slash(path))
  let tail = pattern.has_suffix("/**") ||
    pattern == "/**" ||
    pattern.has_suffix("**")
  let effective : Array[String] = if tail {
    // 去掉模式末尾的 `**` 占位，剩下的段必须逐段命中
    trim_tail_wildcard(pattern_parts)
  } else {
    pattern_parts
  }
  if tail {
    if path_parts.length() < effective.length() {
      false
    } else {
      let mut ok = true
      let mut index = 0
      while index < effective.length() {
        if !segment_match(effective[index], path_parts[index]) {
          ok = false
        }
        index += 1
      }
      ok
    }
  } else if path_parts.length() != effective.length() {
    false
  } else {
    let mut ok = true
    let mut index = 0
    while index < effective.length() {
      if !segment_match(effective[index], path_parts[index]) {
        ok = false
      }
      index += 1
    }
    ok
  }
}

///|
fn strip_head_slash(s : String) -> String {
  if s.has_prefix("/") {
    s[1:].to_owned()
  } else {
    s
  }
}

///|
fn split_path(s : String) -> Array[String] {
  @port.split_by(s, '/')
}

///|
fn trim_tail_wildcard(parts : Array[String]) -> Array[String] {
  let out : Array[String] = []
  for p in parts {
    if p != "**" {
      out.push(p)
    }
  }
  out
}

///|
/// 从请求里取 token：`token_name` 头（可剥 `token_prefix`）。取不到给空串，由 check_login 报 AbsentToken。
pub fn[S, P] extract_token(
  auth : @app.TokenAuth[S, P],
  request : RequestFns,
) -> String {
  let raw = match (request.header)(auth.config.token_name) {
    None => ""
    Some(v) => v
  }
  let prefix = auth.config.token_prefix
  if prefix.is_empty() {
    raw.trim().to_owned()
  } else if raw.has_prefix(prefix) {
    raw[prefix.length():].to_owned().trim().to_owned()
  } else {
    ""
  }
}

///|
/// 守卫裁决的两种放行，**语义不同，必须能区分**：
/// · `Exempt` —— 不在保护面（或命中豁免），放行但**没有主体**；handler 不该拿它当 login_id
/// · `Passed` —— 认证通过（追加断言也已跑完），带 `login_id`
///
/// 0.1.1 及之前这里返回的是 `Ok(String)`，豁免分支塞的是**路径**——调用方一照面就把
/// `login_id == "/api/public/ping"` 这种假值往业务里传。已判定为缺陷并改掉（未投产，直接前进）。
pub(all) enum GuardOutcome {
  Exempt
  Passed(String)
}

///|
/// 守卫裁决：不在保护面内 ⇒ `Ok(Exempt)`（放行且无主体）；在 ⇒ 跑登录校验 + 追加断言，
/// 成功给 `Ok(Passed(login_id))`，失败给 `Err`。
pub async fn[S : @port.TokenStore, P] run_guard(
  auth : @app.TokenAuth[S, P],
  route_guard : RouteGuard,
  request : RequestFns,
) -> Result[GuardOutcome, @port.TokenError] {
  let path = (request.path)()
  let mut needs_auth = false
  for rule in route_guard.rules {
    if matches_path(rule.pattern, path) && !rule.except {
      needs_auth = true
    }
  }
  for rule in route_guard.rules {
    if rule.except && matches_path(rule.pattern, path) {
      // 豁免优先级最高：先匹配后排除
      needs_auth = false
    }
  }
  if !needs_auth {
    Ok(Exempt)
  } else {
    let token = extract_token(auth, request)
    try {
      let login_id = auth.check_login(token)
      for check in route_guard.checks {
        (check.run)(login_id, token)
      }
      Ok(Passed(login_id))
    } catch {
      err => Err(err)
    }
  }
}
