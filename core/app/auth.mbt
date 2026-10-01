///|
/// 应用服务：**一个用例一个方法**，方法体只做四步——取聚合 → 调领域服务 → 提交补丁 → 发事件。
/// 判定规则不在这里（全在 `core/policy`）；HTTP 语义也不在这里（v2 防腐层）。
/// token 一律显式传参（owner 10-01 拍 A 方案：core 保持零 web 依赖）。

///|
pub(all) struct TokenAuth[S, P] {
  realm : String
  config : TokenConfig
  store : S
  perms : P
  style : @style.TokenStyleFns
  keys : @port.KeySpace
  events : @event.EventHub
}

///|
pub fn[S, P] TokenAuth::new(
  realm : String,
  config : TokenConfig,
  store : S,
  perms : P,
  style : @style.TokenStyleFns,
) -> TokenAuth[S, P] {
  let auth : TokenAuth[S, P] = {
    realm,
    config,
    store,
    perms,
    style,
    keys: @port.KeySpace::of(realm),
    events: @event.EventHub::new(),
  }
  auth
}

///|
pub async fn[S : @port.TokenStore, P] TokenAuth::read_session(
  self : TokenAuth[S, P],
  token : String,
) -> @domain.TokenSession? raise @port.TokenError {
  match self.store.get(self.keys.token(token)) {
    None => None
    Some(payload) => @domain.TokenSession::parse(token, payload)
  }
}

///|
pub async fn[S : @port.TokenStore, P] TokenAuth::load_family(
  self : TokenAuth[S, P],
  login_id : String,
) -> @domain.AccountFamily raise @port.TokenError {
  match self.store.get(self.keys.family(login_id)) {
    None => @domain.AccountFamily::empty(login_id)
    Some(payload) =>
      match @domain.AccountFamily::parse(login_id, payload) {
        None => @domain.AccountFamily::empty(login_id)
        Some(fam) => fam
      }
  }
}

///|
/// 封禁查询：到期即视为无封禁并顺手回收脏行（读路径判定，不留状态堆积）
pub async fn[S : @port.TokenStore, P] TokenAuth::ban_of(
  self : TokenAuth[S, P],
  login_id : String,
) -> @port.BanRecord? raise @port.TokenError {
  let key = self.keys.ban(login_id)
  match self.store.get(key) {
    None => None
    Some(payload) =>
      match @port.BanRecord::decode(payload) {
        None => None
        Some(ban) =>
          if ban.until <= @port.now_ms() {
            self.store.apply(@port.RemoveKeys([key]))
            None
          } else {
            Some(ban)
          }
      }
  }
}

///|
pub async fn[S : @port.TokenStore, P] TokenAuth::is_disabled(
  self : TokenAuth[S, P],
  login_id : String,
) -> Bool raise @port.TokenError {
  match self.ban_of(login_id) {
    None => false
    Some(_) => true
  }
}

///|
/// 签发内部件：`login` 与 `rotate` 共用，事件由各调用方决定发哪一种。
/// 一次做完三处写：会话记录、refresh 绑定、反查族索引。
async fn[S : @port.TokenStore, P] TokenAuth::issue(
  self : TokenAuth[S, P],
  login_id : String,
  device : @port.Device,
  remember : Bool,
) -> LoginResult raise @port.TokenError {
  let now = @port.now_ms()
  let span = if remember {
    self.config.remember_timeout_ms()
  } else {
    self.config.timeout_ms()
  }
  let expire_at = @policy.expire_at_of(now, span)
  let token = (self.style.generate)()
  let refresh_token = (self.style.generate)()
  let session = @domain.TokenSession::make(
    token, login_id, device, now, expire_at,
  )
  session.set_refresh_token(refresh_token)
  self.store.set(self.keys.token(token), session.payload(), expire_at)
  self.store.set(
    self.keys.refresh(refresh_token),
    @port.RefreshRecord::make(login_id, device.id, token).encode(),
    @policy.expire_at_of(now, self.config.refresh_timeout_ms()),
  )
  self.store.apply(@port.AddToken(login_id, device, token, expire_at))
  LoginResult::make(token, login_id, device.id, expire_at, refresh_token, false)
}

///|
pub async fn[S : @port.TokenStore, P] TokenAuth::login(
  self : TokenAuth[S, P],
  login_id : String,
  device? : String = "",
  remember? : Bool = false,
) -> LoginResult raise @port.TokenError {
  if login_id.trim().is_empty() {
    // 主键缺失是调用方写错了，必须响亮报错，不能拿空串当身份落库
    raise @port.InvalidInput("login_id must not be empty")
  }
  match self.ban_of(login_id) {
    None => ()
    Some(ban) => raise @port.Disabled(ban.reason, ban.until)
  }
  let now = @port.now_ms()
  let use_remember = remember
  let dev = @port.Device::normalize(Some(device))
  let fam = self.load_family(login_id)
  let plan = @policy.decide_concurrent(self.config.concurrent, fam, dev, now)
  match plan.action {
    @policy.IssueNew => {
      // Supersede 策略：先把既有 token 落成"被顶"墓碑，再签新的
      if !plan.supersede_tokens.is_empty() {
        let deadline = @policy.kick_deadline(now, self.config.kick_grace_ms())
        self.store.apply(
          @port.MarkStatus(plan.supersede_tokens, @port.Superseded, deadline),
        )
        for old in plan.supersede_tokens {
          self.events.fire(
            @event.TokenEvent::make(
              @event.Superseded,
              login_id,
              dev.id,
              old,
              now,
            ),
          )
        }
      }
      let result = self.issue(login_id, dev, use_remember)
      self.events.fire(
        @event.TokenEvent::make(
          @event.LoggedIn,
          login_id,
          dev.id,
          result.token,
          now,
        ),
      )
      result
    }
    @policy.Reuse(existing) =>
      match self.read_session(existing) {
        None => {
          // 族里记着但会话已没：退回新签，别把一个死 token 当有效返回
          let result = self.issue(login_id, dev, use_remember)
          self.events.fire(
            @event.TokenEvent::make(
              @event.LoggedIn,
              login_id,
              dev.id,
              result.token,
              now,
            ),
          )
          result
        }
        Some(session) =>
          if @policy.classify_access(session.status(), session.expire_at(), now)
            is None {
            LoginResult::make(
              existing,
              login_id,
              session.device().id,
              session.expire_at(),
              session.refresh_token(),
              true,
            )
          } else {
            let result = self.issue(login_id, dev, use_remember)
            self.events.fire(
              @event.TokenEvent::make(
                @event.LoggedIn,
                login_id,
                dev.id,
                result.token,
                now,
              ),
            )
            result
          }
      }
  }
}

///|
/// 鉴权裁决单点：空 token / 无会话 / 墓碑态 / 过期 / 活跃超时 / 封禁各报各的原因
pub async fn[S : @port.TokenStore, P] TokenAuth::check_login(
  self : TokenAuth[S, P],
  token : String,
) -> String raise @port.TokenError {
  if token.trim().is_empty() {
    raise @port.NotLogin(@port.AbsentToken)
  }
  let session = match self.read_session(token) {
    None => raise @port.NotLogin(@port.UnknownToken)
    Some(s) => s
  }
  let now = @port.now_ms()
  match @policy.classify_access(session.status(), session.expire_at(), now) {
    None => ()
    Some(reason) => raise @port.NotLogin(reason)
  }
  match self.ban_of(session.login_id()) {
    None => ()
    Some(ban) => raise @port.Disabled(ban.reason, ban.until)
  }
  let decision = @policy.decide_renewal(
    @policy.RenewalInput::make(
      self.config.renewal,
      session.expire_at(),
      session.last_active(),
      self.config.timeout_ms(),
      self.config.active_timeout_ms(),
      self.config.renew_min_interval_ms(),
      now,
    ),
  )
  match decision {
    @policy.Skip => ()
    @policy.Renew(target) => {
      session.touch(now)
      session.renew(now, target)
      self.store.set(self.keys.token(token), session.payload(), target)
    }
    @policy.IdleExpired => raise @port.NotLogin(@port.ActiveTimeout)
  }
  session.login_id()
}

///|
pub async fn[S : @port.TokenStore, P] TokenAuth::is_login(
  self : TokenAuth[S, P],
  token : String,
) -> Bool {
  try {
    self.check_login(token) |> ignore
    true
  } catch {
    _ => false
  }
}

///|
fn targets_of(fam : @domain.AccountFamily, device : String) -> Array[String] {
  if device.is_empty() {
    // 空串＝不限设备：给出该账号全部有效 token
    fam.all_tokens()
  } else {
    fam.tokens_of_device(@port.Device::normalize(Some(device)))
  }
}

///|
/// 墓碑族操作：踢人/顶人共用，只换状态与事件类型
async fn[S : @port.TokenStore, P] TokenAuth::mark_tokens(
  self : TokenAuth[S, P],
  login_id : String,
  targets : Array[String],
  status : @port.SessionStatus,
  event_type : @event.TokenEventType,
) -> Int raise @port.TokenError {
  if targets.is_empty() {
    0
  } else {
    let now = @port.now_ms()
    let deadline = @policy.kick_deadline(now, self.config.kick_grace_ms())
    self.store.apply(@port.MarkStatus(targets, status, deadline))
    for token in targets {
      self.events.fire(
        @event.TokenEvent::make(event_type, login_id, "", token, now),
      )
    }
    targets.length()
  }
}

///|
/// 注销漏斗（单一出口）：T 键删 + 反查族摘除 + 绑定的 refresh 一并失效，不留孤儿键
pub async fn[S : @port.TokenStore, P] TokenAuth::logout(
  self : TokenAuth[S, P],
  token : String,
) -> Unit raise @port.TokenError {
  match self.read_session(token) {
    None => ()
    Some(session) => {
      let login_id = session.login_id()
      let refresh = session.refresh_token()
      self.store.apply(@port.RemoveTokens(login_id, [token]))
      if !refresh.is_empty() {
        self.store.apply(@port.RemoveKeys([self.keys.refresh(refresh)]))
      }
      self.events.fire(
        @event.TokenEvent::make(
          @event.LoggedOut,
          login_id,
          session.device().id,
          token,
          @port.now_ms(),
        ),
      )
    }
  }
}

///|
pub async fn[S : @port.TokenStore, P] TokenAuth::logout_by_id(
  self : TokenAuth[S, P],
  login_id : String,
  device? : String = "",
) -> Int raise @port.TokenError {
  let fam = self.load_family(login_id)
  let targets = targets_of(fam, device)
  self.store.apply(@port.RemoveTokens(login_id, targets))
  let now = @port.now_ms()
  for token in targets {
    self.events.fire(
      @event.TokenEvent::make(@event.LoggedOut, login_id, "", token, now),
    )
  }
  targets.length()
}

///|
pub async fn[S : @port.TokenStore, P] TokenAuth::kickout(
  self : TokenAuth[S, P],
  login_id : String,
  device? : String = "",
) -> Int raise @port.TokenError {
  let fam = self.load_family(login_id)
  self.mark_tokens(
    login_id,
    targets_of(fam, device),
    @port.Kicked,
    @event.Kicked,
  )
}

///|
pub async fn[S : @port.TokenStore, P] TokenAuth::supersede(
  self : TokenAuth[S, P],
  login_id : String,
  device? : String = "",
) -> Int raise @port.TokenError {
  let fam = self.load_family(login_id)
  self.mark_tokens(
    login_id,
    targets_of(fam, device),
    @port.Superseded,
    @event.Superseded,
  )
}

///|
pub async fn[S : @port.TokenStore, P] TokenAuth::disable(
  self : TokenAuth[S, P],
  login_id : String,
  duration : @port.Duration,
  reason? : String = "",
) -> Unit raise @port.TokenError {
  let now = @port.now_ms()
  let until = @policy.expire_at_of(now, duration.to_millis())
  let text = reason
  self.store.apply(
    @port.PutRecord(
      self.keys.ban(login_id),
      @port.BanRecord::make(until, text).encode(),
      until,
    ),
  )
  self.events.fire(
    @event.TokenEvent::make(@event.Disabled, login_id, "", "", now),
  )
}

///|
pub async fn[S : @port.TokenStore, P] TokenAuth::undo_disable(
  self : TokenAuth[S, P],
  login_id : String,
) -> Unit raise @port.TokenError {
  self.store.apply(@port.RemoveKeys([self.keys.ban(login_id)]))
  self.events.fire(
    @event.TokenEvent::make(@event.Enabled, login_id, "", "", @port.now_ms()),
  )
}

///|
/// 在线列表：只列 Active 且未过期的会话（墓碑与脏行都不许出现在这里）
pub async fn[S : @port.TokenStore, P] TokenAuth::get_token_list_by_login_id(
  self : TokenAuth[S, P],
  login_id : String,
) -> Array[TokenInfo] raise @port.TokenError {
  let fam = self.load_family(login_id)
  let now = @port.now_ms()
  let out : Array[TokenInfo] = []
  for mbr in fam.members() {
    if mbr.alive(now) {
      match self.read_session(mbr.token) {
        None => ()
        Some(session) =>
          if @policy.classify_access(session.status(), session.expire_at(), now)
            is None {
            out.push(
              TokenInfo::make(
                mbr.token,
                session.device().id,
                session.expire_at(),
                session.login_time(),
              ),
            )
          }
      }
    }
  }
  out
}

///|
pub async fn[S : @port.TokenStore, P] TokenAuth::get_device_list(
  self : TokenAuth[S, P],
  login_id : String,
) -> Array[String] raise @port.TokenError {
  // 与在线列表同判据：被踢/被顶的会话所在设备不算在线（不能只数反查族成员）
  let list = self.get_token_list_by_login_id(login_id)
  let out : Array[String] = []
  for info in list {
    if !out.contains(info.device) {
      out.push(info.device)
    }
  }
  out
}

///|
/// 取授权集：先过鉴权（含封禁与时效），再向业务端口要数
async fn[S : @port.TokenStore, P : @port.PermissionProvider] TokenAuth::granted(
  self : TokenAuth[S, P],
  token : String,
  roles : Bool,
) -> Array[String] raise @port.TokenError {
  let login_id = self.check_login(token)
  let dev = match self.read_session(token) {
    None => raise @port.NotLogin(@port.UnknownToken)
    Some(s) => s.device()
  }
  if roles {
    self.perms.get_roles(login_id, Some(dev))
  } else {
    self.perms.get_permissions(login_id, Some(dev))
  }
}

///|
pub async fn[S : @port.TokenStore, P : @port.PermissionProvider] TokenAuth::has_permission(
  self : TokenAuth[S, P],
  token : String,
  required : Array[String],
  mode? : @port.MatchMode = @port.And,
) -> Bool raise @port.TokenError {
  let granted = self.granted(token, false)
  @policy.decide_permission(granted, required, mode) is None
}

///|
pub async fn[S : @port.TokenStore, P : @port.PermissionProvider] TokenAuth::check_permission(
  self : TokenAuth[S, P],
  token : String,
  required : Array[String],
  mode? : @port.MatchMode = @port.And,
) -> Unit raise @port.TokenError {
  let granted = self.granted(token, false)
  match @policy.decide_permission(granted, required, mode) {
    None => ()
    Some(missing) => raise @port.NotPermission(missing)
  }
}

///|
pub async fn[S : @port.TokenStore, P : @port.PermissionProvider] TokenAuth::has_role(
  self : TokenAuth[S, P],
  token : String,
  required : Array[String],
  mode? : @port.MatchMode = @port.And,
) -> Bool raise @port.TokenError {
  let granted = self.granted(token, true)
  @policy.decide_role(granted, required, mode) is None
}

///|
pub async fn[S : @port.TokenStore, P : @port.PermissionProvider] TokenAuth::check_role(
  self : TokenAuth[S, P],
  token : String,
  required : Array[String],
  mode? : @port.MatchMode = @port.And,
) -> Unit raise @port.TokenError {
  let granted = self.granted(token, true)
  match @policy.decide_role(granted, required, mode) {
    None => ()
    Some(missing) => raise @port.NotRole(missing)
  }
}

///|
pub async fn[S : @port.TokenStore, P] TokenAuth::get_account_session(
  self : TokenAuth[S, P],
  login_id : String,
) -> @port.AccountSessionRecord? raise @port.TokenError {
  match self.store.get(self.keys.account_session(login_id)) {
    None => None
    Some(payload) => @port.AccountSessionRecord::decode(payload)
  }
}

///|
/// `value = None` 即删该属性（空串不算删除——13 栈"''≠NULL"的同款教训）
pub async fn[S : @port.TokenStore, P] TokenAuth::update_account_session(
  self : TokenAuth[S, P],
  login_id : String,
  key : String,
  value : String?,
) -> Unit raise @port.TokenError {
  if key.is_empty() {
    raise @port.InvalidInput("session attribute key must not be empty")
  }
  let record = match self.get_account_session(login_id) {
    None => @port.AccountSessionRecord::make(login_id)
    Some(r) => r
  }
  match value {
    None => record.attrs.remove(key) |> ignore
    Some(v) => record.attrs[key] = v
  }
  let fam = self.load_family(login_id)
  self.store.apply(
    @port.PutRecord(
      self.keys.account_session(login_id),
      record.encode(),
      fam.max_expire(),
    ),
  )
}

///|
pub async fn[S : @port.TokenStore, P] TokenAuth::get_token_session(
  self : TokenAuth[S, P],
  token : String,
) -> @domain.TokenSession? raise @port.TokenError {
  self.read_session(token)
}

///|
pub async fn[S : @port.TokenStore, P] TokenAuth::update_token_session(
  self : TokenAuth[S, P],
  token : String,
  key : String,
  value : String?,
) -> Unit raise @port.TokenError {
  match self.read_session(token) {
    None => raise @port.NotLogin(@port.UnknownToken)
    Some(session) => {
      if key.is_empty() {
        raise @port.InvalidInput("session attribute key must not be empty")
      }
      session.set_extra(key, value)
      self.store.set(
        self.keys.token(token),
        session.payload(),
        session.expire_at(),
      )
    }
  }
}

///|
/// refresh 全量轮转（13 栈 UC-0113 口径）：旧 access 与旧 refresh 同时失效，返回全新对。
/// **不校验"绑定 access 仍存活"**——access TTL 远短于 refresh，校验必误杀闲置续命场景；
/// 注销漏斗已联动删 refresh 键，`get_and_del` 取不到就是失效，重放防护不丢。
pub async fn[S : @port.TokenStore, P] TokenAuth::rotate(
  self : TokenAuth[S, P],
  refresh_token : String,
) -> LoginResult raise @port.TokenError {
  if refresh_token.trim().is_empty() {
    raise @port.NotLogin(@port.RefreshInvalid)
  }
  let binding = match self.store.get_and_del(self.keys.refresh(refresh_token)) {
    None => raise @port.NotLogin(@port.RefreshInvalid)
    Some(payload) =>
      match @port.RefreshRecord::decode(payload) {
        None => raise @port.NotLogin(@port.RefreshInvalid)
        Some(record) => record
      }
  }
  // 旧 access 一并作废：全量轮转的语义是"整对换新"
  self.store.apply(@port.RemoveTokens(binding.login_id, [binding.access_token]))
  let result = self.issue(
    binding.login_id,
    @port.Device::of(binding.device_id),
    false,
  )
  self.events.fire(
    @event.TokenEvent::make(
      @event.Refreshed,
      binding.login_id,
      binding.device_id,
      result.token,
      @port.now_ms(),
    ),
  )
  result
}

///|
pub fn[S, P] TokenAuth::on_event(
  self : TokenAuth[S, P],
  listener : (@event.TokenEvent) -> Unit raise,
) -> Unit {
  self.events.subscribe(listener)
}

///|
pub fn[S, P] TokenAuth::listener_count(self : TokenAuth[S, P]) -> Int {
  self.events.listener_count()
}

///|
/// 过期回收：长驻服务可定时调，测试用它断言"内存不泄漏"
pub async fn[S : @port.TokenStore, P] TokenAuth::sweep(
  self : TokenAuth[S, P],
) -> Int raise @port.TokenError {
  self.store.sweep(@port.now_ms())
}
