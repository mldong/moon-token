///|
/// 聚合根 `TokenSession`（令牌级会话）。不变量由方法单点保证，不外泄给应用层：
/// ① status 只能 Active→墓碑（Kicked/Superseded）单向迁移，墓碑态不可复活；
/// ② expire_at 只经 renew/mark_* 改动；③ extra 键为空即删除该键（不留空串脏值）。
pub(all) struct TokenSession {
  mut token : String
  mut record : @port.SessionRecord
}

///|
pub fn TokenSession::make(
  token : String,
  login_id : String,
  device : @port.Device,
  at : Int64,
  expire_at : Int64,
) -> TokenSession {
  let s : TokenSession = {
    token,
    record: @port.SessionRecord::make(login_id, device, at, expire_at),
  }
  s
}

///|
pub fn TokenSession::parse(token : String, payload : String) -> TokenSession? {
  match @port.SessionRecord::decode(payload) {
    None => None
    Some(record) => {
      let s : TokenSession = { token, record, }
      Some(s)
    }
  }
}

///|
pub fn TokenSession::payload(self : TokenSession) -> String {
  self.record.encode()
}

///|
pub fn TokenSession::token(self : TokenSession) -> String {
  self.token
}

///|
pub fn TokenSession::login_id(self : TokenSession) -> String {
  self.record.login_id
}

///|
pub fn TokenSession::device(self : TokenSession) -> @port.Device {
  self.record.device
}

///|
pub fn TokenSession::login_time(self : TokenSession) -> Int64 {
  self.record.login_time
}

///|
pub fn TokenSession::expire_at(self : TokenSession) -> Int64 {
  self.record.expire_at
}

///|
pub fn TokenSession::last_active(self : TokenSession) -> Int64 {
  self.record.last_active
}

///|
pub fn TokenSession::status(self : TokenSession) -> @port.SessionStatus {
  self.record.status
}

///|
pub fn TokenSession::refresh_token(self : TokenSession) -> String {
  self.record.refresh_token
}

///|
pub fn TokenSession::extra(self : TokenSession, key : String) -> String? {
  self.record.extra.get(key)
}

///|
pub fn TokenSession::extra_entries(
  self : TokenSession,
) -> Array[(String, String)] {
  self.record.extra.to_array()
}

///|
pub fn TokenSession::set_extra(
  self : TokenSession,
  key : String,
  value : String?,
) -> Unit {
  if key.is_empty() {
    ()
  } else {
    match value {
      None => self.record.extra.remove(key) |> ignore
      Some(v) => self.record.extra[key] = v
    }
  }
}

///|
pub fn TokenSession::set_refresh_token(
  self : TokenSession,
  refresh : String,
) -> Unit {
  self.record.refresh_token = refresh
}

///|
/// 滑动续期：只推进到期时刻与活跃标记，不改状态
pub fn TokenSession::renew(
  self : TokenSession,
  now : Int64,
  expire_at : Int64,
) -> Unit {
  self.record.last_active = now
  if expire_at > self.record.expire_at {
    self.record.expire_at = expire_at
  }
}

///|
/// 活跃标记（IdleMark 模式用）：只更新 last_active
pub fn TokenSession::touch(self : TokenSession, now : Int64) -> Unit {
  self.record.last_active = now
}

///|
fn TokenSession::mark_tombstone(
  self : TokenSession,
  status : @port.SessionStatus,
  deadline : Int64,
) -> Bool {
  // 单向迁移：非 Active 的会话已经是墓碑，不重复置位（幂等）
  if !self.record.status.same(@port.SessionStatus::Active) {
    false
  } else {
    self.record.status = status
    self.record.expire_at = deadline
    true
  }
}

///|
pub fn TokenSession::mark_kicked(self : TokenSession, deadline : Int64) -> Bool {
  self.mark_tombstone(@port.SessionStatus::Kicked, deadline)
}

///|
pub fn TokenSession::mark_superseded(
  self : TokenSession,
  deadline : Int64,
) -> Bool {
  self.mark_tombstone(@port.SessionStatus::Superseded, deadline)
}

///|
pub fn TokenSession::is_alive(self : TokenSession, now : Int64) -> Bool {
  self.record.expire_at <= 0L || self.record.expire_at > now
}

///|
/// 剩余有效毫秒（不过期档返回 -1，供节流判定与在线列表展示）
pub fn TokenSession::remaining_ms(self : TokenSession, now : Int64) -> Int64 {
  if self.record.expire_at <= 0L {
    -1L
  } else {
    let left = self.record.expire_at - now
    if left < 0L {
      0L
    } else {
      left
    }
  }
}

///|
/// 聚合根 `AccountFamily`（账号级反查族）：token→loginId 正查靠它，踢人/顶人/在线列表全靠它。
/// 不变量：① 族内不得含已过期成员（`prune_expired` 承担清扫义务）；
/// ② 一个 token 只属一个族（`add_member` 判重即幂等）；③ version 只随成员增删单调递增。
pub(all) struct AccountFamily {
  mut record : @port.FamilyRecord
}

///|
pub fn AccountFamily::empty(login_id : String) -> AccountFamily {
  let f : AccountFamily = { record: @port.FamilyRecord::empty(login_id), }
  f
}

///|
pub fn AccountFamily::parse(
  login_id : String,
  payload : String,
) -> AccountFamily? {
  match @port.FamilyRecord::decode(payload) {
    None => None
    Some(record) =>
      // 键位里的 login_id 与载荷里的必须一致，否则说明读写两侧键位串了
      if record.login_id != login_id {
        None
      } else {
        let f : AccountFamily = { record, }
        Some(f)
      }
  }
}

///|
pub fn AccountFamily::payload(self : AccountFamily) -> String {
  self.record.encode()
}

///|
pub fn AccountFamily::login_id(self : AccountFamily) -> String {
  self.record.login_id
}

///|
pub fn AccountFamily::version(self : AccountFamily) -> Int64 {
  self.record.version
}

///|
pub fn AccountFamily::members(
  self : AccountFamily,
) -> Array[@port.FamilyMember] {
  self.record.members
}

///|
pub fn AccountFamily::all_tokens(self : AccountFamily) -> Array[String] {
  self.record.all_tokens()
}

///|
pub fn AccountFamily::tokens_of_device(
  self : AccountFamily,
  device : @port.Device,
) -> Array[String] {
  self.record.tokens_of_device(device)
}

///|
pub fn AccountFamily::has_token(self : AccountFamily, token : String) -> Bool {
  self.record.has_token(token)
}

///|
pub fn AccountFamily::find_device(
  self : AccountFamily,
  device : @port.Device,
) -> @port.FamilyMember? {
  self.record.find_device(device)
}

///|
/// 加成员；已在族里（同 token）就是空操作，返回"是否真的新增了"。
/// `login_time` 不给默认值：上限淘汰按它定序，静默落成 0 会让这台设备永远排最前。
pub fn AccountFamily::add_member(
  self : AccountFamily,
  device : @port.Device,
  token : String,
  expire_at : Int64,
  login_time : Int64,
) -> Bool {
  if self.record.has_token(token) {
    false
  } else {
    self.record.members.push(
      @port.FamilyMember::make(device, token, expire_at, login_time),
    )
    self.record.version += 1L
    true
  }
}

///|
/// 摘成员；返回摘掉的条数（0 表示空操作）
pub fn AccountFamily::remove_members(
  self : AccountFamily,
  tokens : Array[String],
) -> Int {
  let before = self.record.members.length()
  self.record.members = self.record.members.filter((m : @port.FamilyMember) => {
    !tokens.contains(m.token)
  })
  let dropped = before - self.record.members.length()
  if dropped > 0 {
    self.record.version += 1L
  }
  dropped
}

///|
/// 清扫已过期成员（内存与后端共同的义务），返回清掉的条数
pub fn AccountFamily::prune_expired(self : AccountFamily, now : Int64) -> Int {
  let (kept, dropped) = self.record.without_expired(now)
  if dropped > 0 {
    self.record.members = kept
    self.record.version += 1L
  }
  dropped
}

///|
pub fn AccountFamily::max_expire(self : AccountFamily) -> Int64 {
  self.record.max_expire()
}

///|
/// 活成员里按登录时刻升序取前 k 个 token（上限淘汰用）。
/// 排序不靠数组顺序——见 `FamilyRecord::oldest_tokens` 那段注释。
pub fn AccountFamily::oldest_tokens(
  self : AccountFamily,
  k : Int,
  now : Int64,
) -> Array[String] {
  self.record.oldest_tokens(k, now)
}

///|
pub fn AccountFamily::is_empty(self : AccountFamily) -> Bool {
  self.record.members.is_empty()
}
