///|
/// 领域服务：并发/续期/权限/访问裁决。**纯函数、零 IO、零 async、不吃全局时钟**
/// （`now` 一律由调用方传入）。这是 DDD 在本项目的落点：判定规则只在这里一份，
/// 应用层出现并发/续期/权限的 if 就是分层破了。

///|
pub(all) enum LoginAction {
  IssueNew
  Reuse(String)
}

///|
pub(all) struct LoginPlan {
  action : LoginAction
  /// 需要置为 Superseded 墓碑的旧 token（Coexist/Shared 下为空）
  supersede_tokens : Array[String]
  /// 因 `max_sessions` 溢出要下线的 token（按登录时刻升序，最老的在前）
  evict_tokens : Array[String]
}

///|
pub fn LoginPlan::make(
  action : LoginAction,
  supersede_tokens : Array[String],
  evict_tokens : Array[String],
) -> LoginPlan {
  let p : LoginPlan = { action, supersede_tokens, evict_tokens, }
  p
}

///|
/// 三态语义（§2 定死）：
/// · Coexist —— 每次新签，旧 token 继续有效
/// · Shared  —— 同 realm 同 device 复用同一 token；该设备无有效 token 才新签
/// · Supersede —— 新签，并把同账号下**全部**既有 token 置 Superseded
///
/// `max_sessions`（`<=0` 或 `-1` 视为不限）：只在这次真的新增一枚时生效，按登录时刻
/// **先进先出**剔最老的，剔完正好回到上限内。`Supersede` 不参与——它本来就把全部旧会话清空，
/// 活成员恒为 1；`Shared` 要参与，因为它是"每设备一枚"，设备数一样能把族撑爆。
pub fn decide_concurrent(
  policy : @port.ConcurrentPolicy,
  family : @domain.AccountFamily,
  device : @port.Device,
  now : Int64,
  max_sessions : Int,
) -> LoginPlan {
  let live_family = family
  live_family.prune_expired(now) |> ignore
  let base = match policy {
    @port.Coexist => LoginPlan::make(IssueNew, [], [])
    @port.Shared => {
      let token = match live_family.find_device(device) {
        None => ""
        Some(existing) => existing.token
      }
      if token.is_empty() {
        LoginPlan::make(IssueNew, [], [])
      } else {
        LoginPlan::make(Reuse(token), [], [])
      }
    }
    @port.Supersede => LoginPlan::make(IssueNew, live_family.all_tokens(), [])
  }
  let cap_applies = match policy {
    @port.Supersede => false
    _ => true
  }
  let is_new_token = match base.action {
    IssueNew => true
    Reuse(_) => false
  }
  if !is_new_token || max_sessions <= 0 || !cap_applies {
    base
  } else {
    let live = live_family.members().length()
    let over = live + 1 - max_sessions
    if over <= 0 {
      base
    } else {
      LoginPlan::make(
        base.action,
        base.supersede_tokens,
        live_family.oldest_tokens(over, now),
      )
    }
  }
}

///|
pub(all) enum RenewalDecision {
  Skip
  /// 续到新的绝对到期时刻
  Renew(Int64)
  /// IdleMark 档：到期点不动，只把这枚会话的活跃时刻标到新时刻
  Mark(Int64)
  /// IdleMark 模式下活跃超时
  IdleExpired
}

///|
pub(all) struct RenewalInput {
  mode : @port.RenewalMode
  expire_at : Int64
  last_active : Int64
  timeout_ms : Int64
  /// <=0 表示不限活跃时效
  active_timeout_ms : Int64
  /// 续期节流窗：距上次续期不足此值不写后端
  min_interval_ms : Int64
  now : Int64
}

///|
pub fn RenewalInput::make(
  mode : @port.RenewalMode,
  expire_at : Int64,
  last_active : Int64,
  timeout_ms : Int64,
  active_timeout_ms : Int64,
  min_interval_ms : Int64,
  now : Int64,
) -> RenewalInput {
  let i : RenewalInput = {
    mode,
    expire_at,
    last_active,
    timeout_ms,
    active_timeout_ms,
    min_interval_ms,
    now,
  }
  i
}

///|
pub fn decide_renewal(input : RenewalInput) -> RenewalDecision {
  match input.mode {
    @port.SlideOnAccess => {
      let since = input.now - input.last_active
      if input.min_interval_ms > 0L && since < input.min_interval_ms {
        // 节流窗内不写后端：v2 的 Redis 后端就是每请求一次 SET，省下来是契约的一部分
        Skip
      } else {
        let target = input.now + input.timeout_ms
        if input.expire_at > 0L && input.expire_at >= target {
          Skip
        } else {
          Renew(target)
        }
      }
    }
    @port.IdleMark => {
      let since = input.now - input.last_active
      if input.active_timeout_ms <= 0L {
        // 没配活跃时效 ⇒ 这一档无事可做
        Skip
      } else if since >= input.active_timeout_ms {
        // 判死排在写回之前：不能因为"来人了"就把已经闲置过头的会话救活
        IdleExpired
      } else if input.min_interval_ms > 0L && since < input.min_interval_ms {
        // 节流窗内不写后端（与 SlideOnAccess 同一把尺子）
        Skip
      } else {
        // 出窗就把活跃时刻标上。**不写回的话 `active_timeout` 就不是"最低活跃频率"，
        // 而退化成"自签发起的固定死线"**——天天在用的会话照样在到点时被判闲置（A41 钉住）
        Mark(input.now)
      }
    }
  }
}

///|
/// 权限/角色判定归库：required 为空即放行（没有"要求零项却不通过"这种语义）。
/// 返回 None 表示通过，Some(缺失项) 表示第一个不满足的项（供错误文案精确化）。
pub fn decide_contains(
  granted : Array[String],
  required : Array[String],
  mode : @port.MatchMode,
) -> String? {
  match mode {
    @port.And => {
      let mut missing = ""
      for item in required {
        if missing.is_empty() && !granted.contains(item) {
          missing = item
        }
      }
      if missing.is_empty() {
        None
      } else {
        Some(missing)
      }
    }
    @port.Or =>
      if required.is_empty() {
        None
      } else if required.any((item : String) => granted.contains(item)) {
        None
      } else {
        Some(required[0])
      }
  }
}

///|
pub fn decide_permission(
  granted : Array[String],
  required : Array[String],
  mode : @port.MatchMode,
) -> String? {
  decide_contains(granted, required, mode)
}

///|
pub fn decide_role(
  granted_roles : Array[String],
  required_roles : Array[String],
  mode : @port.MatchMode,
) -> String? {
  decide_contains(granted_roles, required_roles, mode)
}

///|
/// 访问裁决单点：把"精确原因"这件事收在一处，应用层与 v2 后端都走它。
/// 返回 None 表示放行。
pub fn classify_access(
  status : @port.SessionStatus,
  expire_at : Int64,
  now : Int64,
) -> @port.NotLoginReason? {
  if status.same(@port.Kicked) {
    Some(@port.KickedOut)
  } else if status.same(@port.Superseded) {
    Some(@port.SupersededByLogin)
  } else if expire_at > 0L && expire_at <= now {
    Some(@port.SessionExpired)
  } else {
    None
  }
}

///|
/// 被踢/被顶后 `T:` 键的保留窗终点（短窗必须远短于 timeout，防状态堆积）
pub fn kick_deadline(now : Int64, grace_ms : Int64) -> Int64 {
  now + grace_ms
}

///|
/// 签发时刻的绝对到期点：expire_ms <= 0 表示不过期（0 存法）
pub fn expire_at_of(now : Int64, expire_ms : Int64) -> Int64 {
  if expire_ms <= 0L {
    0L
  } else {
    now + expire_ms
  }
}
