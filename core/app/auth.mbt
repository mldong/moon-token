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
  extra : Map[String, String]?,
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
  match extra {
    Some(m) => for k, v in m {
      session.set_extra(k, Some(v))
    }
    None => ()
  }
  session.set_refresh_token(refresh_token)
  self.store.set(
    self.keys.token(token),
    session.payload(),
    self.config.key_expire_at(expire_at),
  )
  self.store.set(
    self.keys.refresh(refresh_token),
    @port.RefreshRecord::make(login_id, device.id, token).encode(),
    @policy.expire_at_of(now, self.config.refresh_timeout_ms()),
  )
  self.store.apply(@port.AddToken(login_id, device, token, expire_at, now))
  LoginResult::make(token, login_id, device.id, expire_at, refresh_token, false)
}

///|
pub async fn[S : @port.TokenStore, P] TokenAuth::login(
  self : TokenAuth[S, P],
  login_id : String,
  device? : String = "",
  remember? : Bool = false,
  extra? : Map[String, String]? = None,
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
  let plan = @policy.decide_concurrent(
    self.config.concurrent,
    fam,
    dev,
    now,
    self.config.max_sessions,
  )
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
      let result = self.issue(login_id, dev, use_remember, extra)
      self.events.fire(
        @event.TokenEvent::make(
          @event.LoggedIn,
          login_id,
          dev.id,
          result.token,
          now,
        ),
      )
      if !plan.evict_tokens.is_empty() {
        self.evict_overflow(login_id, plan.evict_tokens, now)
      }
      result
    }
    @policy.Reuse(existing) =>
      match self.read_session(existing) {
        None => {
          // 族里记着但会话已没：退回新签，别把一个死 token 当有效返回
          let result = self.issue(login_id, dev, use_remember, extra)
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
            // 复用同一枚 token 也算"又登录了一次"：成员要移回队尾。
            // 不刷新的话，一台天天复登的老设备在先进先出里永远排最前，会被上限先剔掉
            self.store.apply(@port.RefreshLogin(login_id, existing, now))
            // 复用会话的 extra 要刷新：登录属性（appCode/ip/ua）以最近一次登录为准——
            // 与 boot2 每次登录重写 session 的 LoginUser 同语义
            match extra {
              Some(m) => {
                for k, v in m {
                  session.set_extra(k, Some(v))
                }
                self.store.set(
                  self.keys.token(existing),
                  session.payload(),
                  self.config.key_expire_at(session.expire_at()),
                )
              }
              None => ()
            }
            LoginResult::make(
              existing,
              login_id,
              session.device().id,
              session.expire_at(),
              session.refresh_token(),
              true,
            )
          } else {
            let result = self.issue(login_id, dev, use_remember, extra)
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
      self.store.set(
        self.keys.token(token),
        session.payload(),
        self.config.key_expire_at(target),
      )
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
/// 被上限剔掉的那一枚怎么下线（`overflow_exit` 三档）。
/// **先读回它绑定的 refresh 再动 `T:`**——注销漏斗是不变量 7：`T` 删 + 族摘 + `R` 联动删。
/// Kick/Supersede 两档走 `ForgetTokens`（只摘成员、留墓碑），否则保留窗内的墓碑
/// 会被下一次登录重新数进上限里。
async fn[S : @port.TokenStore, P] TokenAuth::evict_overflow(
  self : TokenAuth[S, P],
  login_id : String,
  tokens : Array[String],
  now : Int64,
) -> Unit raise @port.TokenError {
  let refresh_keys : Array[String] = []
  for old in tokens {
    match self.read_session(old) {
      None => ()
      Some(session) => {
        let bound = session.refresh_token()
        if !bound.is_empty() {
          refresh_keys.push(self.keys.refresh(bound))
        }
      }
    }
  }
  self.clear_grants(tokens)
  let deadline = @policy.kick_deadline(now, self.config.kick_grace_ms())
  match self.config.overflow_exit {
    @port.Logout => {
      self.store.apply(@port.RemoveTokens(login_id, tokens))
      for old in tokens {
        self.events.fire(
          @event.TokenEvent::make(@event.LoggedOut, login_id, "", old, now),
        )
      }
    }
    @port.Kick => {
      self.store.apply(@port.MarkStatus(tokens, @port.Kicked, deadline))
      self.store.apply(@port.ForgetTokens(login_id, tokens))
      for old in tokens {
        self.events.fire(
          @event.TokenEvent::make(@event.Kicked, login_id, "", old, now),
        )
      }
    }
    @port.Supersede => {
      self.store.apply(@port.MarkStatus(tokens, @port.Superseded, deadline))
      self.store.apply(@port.ForgetTokens(login_id, tokens))
      for old in tokens {
        self.events.fire(
          @event.TokenEvent::make(@event.Superseded, login_id, "", old, now),
        )
      }
    }
  }
  if !refresh_keys.is_empty() {
    self.store.apply(@port.RemoveKeys(refresh_keys))
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
      // 快照跟着会话一起作废：下一次登录必须重新问业务
      self.clear_grants([token])
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
  self.clear_grants(targets)
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
  self.clear_grants(targets_of(fam, device))
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
  self.clear_grants(targets_of(fam, device))
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
  operator? : String = "",
) -> Unit raise @port.TokenError {
  let now = @port.now_ms()
  let until = @policy.expire_at_of(now, duration.to_millis())
  let text = reason
  let who = operator
  self.store.apply(
    @port.PutRecord(
      self.keys.ban(login_id),
      @port.BanRecord::make(until, text, who, now).encode(),
      until,
    ),
  )
  // 禁用是账号级动作：把该账号所有会话的授权快照一并作废（解禁后下一次问业务拿新数）
  let fam = self.load_family(login_id)
  self.clear_grants(targets_of(fam, ""))
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
/// 跨账号枚举在线会话（mldong 在线用户列表那一页的入口）。
/// 两步走是刻意的：这一步只拿**索引级条目**（登录时刻反序 + 游标翻页），详情由 `load_online`
/// 一次批量取——一页合计两次往返，而不是"枚举 + 逐会话 + 逐 token"那种 1+N+ΣM 的形状。
/// **判活不在枚举这一步做**：索引是派生缓存，权威在 `T:`，取不到载荷的自然被丢掉。
pub async fn[S : @port.TokenStore, P] TokenAuth::list_online(
  self : TokenAuth[S, P],
  filter : @port.SessionFilter,
  cursor : String,
  limit : Int,
) -> @port.SessionPage raise @port.TokenError {
  self.store.list_sessions(filter, cursor, limit)
}

///|
/// 取一页的详情：顺序与 `page.items` 一致；`None`＝这条已经不在线（索引落后于事实时的正常现象，
/// 宁可少几条也不返回错数据）
pub async fn[S : @port.TokenStore, P] TokenAuth::load_online(
  self : TokenAuth[S, P],
  page : @port.SessionPage,
) -> Array[OnlineRow] raise @port.TokenError {
  let keys = page.items.map((item : @port.SessionListing) =>
    self.keys.token(item.token))
  let rows = self.store.get_many(keys)
  let out : Array[OnlineRow] = []
  let mut i = 0
  while i < page.items.length() {
    let row = rows[i]
    let record = match row.1 {
      None => None
      Some(payload) => @port.SessionRecord::decode(payload)
    }
    out.push(OnlineRow::make(page.items[i], record))
    i += 1
  }
  out
}

///|
/// 删授权快照：键按 token，所以"会话终结 ⇒ 快照作废"落在同一条键上，不需要猜设备、也不用扫前缀。
async fn[S : @port.TokenStore, P] TokenAuth::clear_grants(
  self : TokenAuth[S, P],
  tokens : Array[String],
) -> Unit raise @port.TokenError {
  if !tokens.is_empty() {
    self.store.del(tokens.map((t : String) => self.keys.grants(t)))
  }
}

///|
/// 取授权快照：命中 `P:` 就用，miss 才问业务三个方法并回填。
/// TTL 跟这条会话同寿（拿它的 `expire_at` 走和 `T:` 同一把尺子 `key_expire_at`）。
/// 滑动续期不搬动快照的到期，所以长会话大约每个 timeout 窗口回填一次——设计好的行为，不是缺陷。
async fn[S : @port.TokenStore, P : @port.PermissionProvider] TokenAuth::load_grants(
  self : TokenAuth[S, P],
  token : String,
  login_id : String,
  device : @port.Device,
  expire_at : Int64,
  extra : Map[String, String],
) -> @port.PermissionRecord raise @port.TokenError {
  let key = self.keys.grants(token)
  let cached = match self.store.get(key) {
    None => None
    Some(payload) => @port.PermissionRecord::decode(payload)
  }
  match cached {
    Some(record) => record
    None => {
      let perms = self.perms.get_permissions(login_id, Some(device), extra)
      let roles = self.perms.get_roles(login_id, Some(device), extra)
      let super_admin = self.perms.is_super_admin(login_id, Some(device), extra)
      let record = @port.PermissionRecord::make(
        login_id,
        perms,
        roles,
        super_admin,
        @port.now_ms(),
      )
      self.store.apply(
        @port.PutRecord(
          key,
          record.encode(),
          self.config.key_expire_at(expire_at),
        ),
      )
      record
    }
  }
}

///|
/// 读授权快照（不判定）：**认证过的主体有谁、够不够什么**都从这里出发。
/// 业务要把权限集/角色集/超管位投影给自己的接口（在线列表的超管列、前端按钮可见性）、
/// 以及 web 中间件判超管，都读它——一次 `T:` 读 + 至多一次快照命中，零业务库往返。
/// 返回的登录号来自 `T:`（权威），不是快照里那一份。
pub async fn[S : @port.TokenStore, P : @port.PermissionProvider] TokenAuth::authenticate(
  self : TokenAuth[S, P],
  token : String,
) -> (String, @port.PermissionRecord) raise @port.TokenError {
  let login_id = self.check_login(token)
  let session = match self.read_session(token) {
    None => raise @port.NotLogin(@port.UnknownToken)
    Some(s) => s
  }
  let record = self.load_grants(
    token,
    login_id,
    session.device(),
    session.expire_at(),
    session.extras(),
  )
  (login_id, record)
}

///|
/// 超管是否跳过权限/角色校验（仍要求已登录）。开关在 `TokenConfig::super_bypass`。
fn super_passes(
  config : TokenConfig,
  record : @port.PermissionRecord,
) -> Bool {
  config.super_bypass && record.super_admin
}

///|
/// 纯判定半边：对**已经拿到**的快照做权限/角色裁决，一次存储读都不做。
/// 拆出来是给 web 适配层用的：中间件通常已经 `authenticate` 过（要把权限集与超管位交给业务），
/// 再走 `check_access` 就会把同一枚会话读第二遍。两个维度之间是 AND，各自按自己的 mode 判，
/// 超管在 `super_bypass` 开着时整段跳过。
pub fn[S, P] TokenAuth::check_principal(
  self : TokenAuth[S, P],
  record : @port.PermissionRecord,
  perms : Array[String],
  perm_mode : @port.MatchMode,
  roles : Array[String],
  role_mode : @port.MatchMode,
) -> Unit raise @port.TokenError {
  if super_passes(self.config, record) {
    ()
  } else {
    match @policy.decide_permission(record.perms, perms, perm_mode) {
      None => ()
      Some(missing) => raise @port.NotPermission(missing)
    }
    match @policy.decide_role(record.roles, roles, role_mode) {
      None => ()
      Some(missing) => raise @port.NotRole(missing)
    }
  }
}

///|
/// 对一枚 token 判"权限集 + 角色集"：一次认证、一次快照，两个维度各自按自己的 mode 判，
/// 两个维度之间是 AND。超管在 `super_bypass` 开着时整段跳过。
pub async fn[S : @port.TokenStore, P : @port.PermissionProvider] TokenAuth::check_access(
  self : TokenAuth[S, P],
  token : String,
  perms : Array[String],
  perm_mode : @port.MatchMode,
  roles : Array[String],
  role_mode : @port.MatchMode,
) -> String raise @port.TokenError {
  let (login_id, record) = self.authenticate(token)
  self.check_principal(record, perms, perm_mode, roles, role_mode)
  login_id
}

///|
/// 作废授权快照。**业务改了某人的角色/权限后必须调它**，否则那个人要到重新登录才拿到新数；
/// 这是缓存换来的代价，不是可选项。
/// `device` 给空串＝该账号族里的全部会话，返回清掉的份数。
pub async fn[S : @port.TokenStore, P] TokenAuth::invalidate_grants(
  self : TokenAuth[S, P],
  login_id : String,
  device? : String = "",
) -> Int raise @port.TokenError {
  let fam = self.load_family(login_id)
  let targets = targets_of(fam, device)
  self.clear_grants(targets)
  targets.length()
}

///|
/// `has_*` 返回 bool、`check_*` 抛缺失项，两条路的判据完全同一条：
/// **先认证（不成立照样抛鉴权错，不是返回 false）**，再读快照，超管开着 `super_bypass` 时整段放行。
pub async fn[S : @port.TokenStore, P : @port.PermissionProvider] TokenAuth::has_permission(
  self : TokenAuth[S, P],
  token : String,
  required : Array[String],
  mode? : @port.MatchMode = @port.And,
) -> Bool raise @port.TokenError {
  let (_, record) = self.authenticate(token)
  if super_passes(self.config, record) {
    true
  } else {
    @policy.decide_permission(record.perms, required, mode) is None
  }
}

///|
pub async fn[S : @port.TokenStore, P : @port.PermissionProvider] TokenAuth::check_permission(
  self : TokenAuth[S, P],
  token : String,
  required : Array[String],
  mode? : @port.MatchMode = @port.And,
) -> Unit raise @port.TokenError {
  let (_, record) = self.authenticate(token)
  if super_passes(self.config, record) {
    ()
  } else {
    match @policy.decide_permission(record.perms, required, mode) {
      None => ()
      Some(missing) => raise @port.NotPermission(missing)
    }
  }
}

///|
pub async fn[S : @port.TokenStore, P : @port.PermissionProvider] TokenAuth::has_role(
  self : TokenAuth[S, P],
  token : String,
  required : Array[String],
  mode? : @port.MatchMode = @port.And,
) -> Bool raise @port.TokenError {
  let (_, record) = self.authenticate(token)
  if super_passes(self.config, record) {
    true
  } else {
    @policy.decide_role(record.roles, required, mode) is None
  }
}

///|
pub async fn[S : @port.TokenStore, P : @port.PermissionProvider] TokenAuth::check_role(
  self : TokenAuth[S, P],
  token : String,
  required : Array[String],
  mode? : @port.MatchMode = @port.And,
) -> Unit raise @port.TokenError {
  let (_, record) = self.authenticate(token)
  if super_passes(self.config, record) {
    ()
  } else {
    match @policy.decide_role(record.roles, required, mode) {
      None => ()
      Some(missing) => raise @port.NotRole(missing)
    }
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
  record.version += 1L
  let fam = self.load_family(login_id)
  // TTL 不能只跟族：账号注销干净后 `max_expire()` 退化成 0＝永不过期，这条键就漏在库里了。
  // 取"族最晚到期"与"本次写入刷新出的 refresh_timeout 下限"里更晚的那个，两头都堵住。
  let by_family = fam.max_expire()
  let floor = @policy.expire_at_of(
    @port.now_ms(),
    self.config.refresh_timeout_ms(),
  )
  let deadline = if by_family > floor {
    by_family
  } else {
    floor
  }
  self.store.apply(
    @port.PutRecord(
      self.keys.account_session(login_id),
      record.encode(),
      deadline,
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
        self.config.key_expire_at(session.expire_at()),
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
  // 轮转延续登录属性：新会话的 extra 从旧会话搬（appCode/ip/ua 不因轮转丢失）
  let old_extra : Map[String, String]? = match self.read_session(binding.access_token) {
    None => None
    Some(old_session) => Some(old_session.extras())
  }
  self.store.apply(@port.RemoveTokens(binding.login_id, [binding.access_token]))
  let result = self.issue(
    binding.login_id,
    @port.Device::of(binding.device_id),
    false,
    old_extra,
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
