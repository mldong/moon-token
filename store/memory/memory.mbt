///|
/// 内存适配器：v1 唯一交付的后端。契约要点——
/// ① 读路径**惰性判过期**（过期即视为不存在并当场回收）；② `apply` 是反向索引唯一写入口；
/// ③ 补丁整体幂等；④ `sweep` 供长驻服务与"内存不泄漏"断言。
pub(all) struct Entry {
  mut payload : String
  /// 绝对到期时刻（ms）；<=0 表示不过期
  mut expire_at : Int64
}

///|
pub fn Entry::make(payload : String, expire_at : Int64) -> Entry {
  let e : Entry = { payload, expire_at, }
  e
}

///|
pub(all) struct MemoryStore {
  entries : Map[String, Entry]
  keys : @port.KeySpace
}

///|
pub fn MemoryStore::new(realm : String) -> MemoryStore {
  let store : MemoryStore = {
    entries: Map([]),
    keys: @port.KeySpace::of(realm),
  }
  store
}

///|
pub fn MemoryStore::size(self : MemoryStore) -> Int {
  self.entries.length()
}

///|
fn is_expired(expire_at : Int64, now : Int64) -> Bool {
  expire_at > 0L && expire_at <= now
}

///|
/// 载荷是"活着的会话"还是"已关窗的墓碑"，决定过期后怎么处置
fn is_live_session_payload(payload : String) -> Bool {
  match @port.SessionRecord::decode(payload) {
    None => false
    Some(record) => record.status.same(@port.SessionStatus::Active)
  }
}

///|
pub fn MemoryStore::lookup(self : MemoryStore, key : String) -> String? {
  let now = @port.now_ms()
  match self.entries.get(key) {
    None => None
    Some(entry) =>
      if is_expired(entry.expire_at, now) {
        if key.contains(":T:") && is_live_session_payload(entry.payload) {
          // 活会话过期要照旧交回载荷，让 classify_access 报 SessionExpired；
          // 若这里一并吞掉，"过期"与"无效"就塌成同一个原因，负向反馈的精度丢了
          Some(entry.payload)
        } else {
          // 墓碑过窗与非会话记录：读到就算它没了，当场回收，不留脏行
          self.entries.remove(key)
          None
        }
      } else {
        Some(entry.payload)
      }
  }
}

///|
pub fn MemoryStore::put(
  self : MemoryStore,
  key : String,
  payload : String,
  expire_at : Int64,
) -> Unit {
  self.entries[key] = Entry::make(payload, expire_at)
}

///|
pub fn MemoryStore::remove(self : MemoryStore, keys : Array[String]) -> Unit {
  for key in keys {
    self.entries.remove(key)
  }
}

///|
pub fn MemoryStore::take(self : MemoryStore, key : String) -> String? {
  let value = self.lookup(key)
  self.entries.remove(key)
  value
}

///|
pub fn MemoryStore::load_family(
  self : MemoryStore,
  login_id : String,
) -> @port.FamilyRecord {
  match self.lookup(self.keys.family(login_id)) {
    None => @port.FamilyRecord::empty(login_id)
    Some(payload) => {
      let decoded = @port.FamilyRecord::decode(payload)
      match decoded {
        None => @port.FamilyRecord::empty(login_id)
        Some(record) => record
      }
    }
  }
}

///|
pub fn MemoryStore::save_family(
  self : MemoryStore,
  login_id : String,
  record : @port.FamilyRecord,
) -> Unit {
  let key = self.keys.family(login_id)
  if record.members.is_empty() {
    self.entries.remove(key)
  } else {
    self.put(key, record.encode(), record.max_expire())
  }
}

///|
/// 改写单个 `T:` 记录的到期时刻与状态（线格式由端口持有，适配器不发明字段名）
fn MemoryStore::revise_token(
  self : MemoryStore,
  token : String,
  status : @port.SessionStatus?,
  expire_at : Int64,
) -> Unit {
  let key = self.keys.token(token)
  match self.entries.get(key) {
    None => ()
    Some(entry) => {
      let decoded = @port.SessionRecord::decode(entry.payload)
      match decoded {
        None => ()
        Some(record) => {
          match status {
            Some(s) => record.status = s
            None => ()
          }
          if expire_at > 0L {
            record.expire_at = expire_at
            entry.payload = record.encode()
            entry.expire_at = expire_at
          } else {
            entry.payload = record.encode()
          }
        }
      }
    }
  }
}

///|
/// 应用意图补丁（同一批按序生效，整体幂等）
pub fn MemoryStore::apply_patch(
  self : MemoryStore,
  patch : @port.FamilyPatch,
) -> Unit {
  match patch {
    @port.AddToken(login_id, device, token, expire_at) => {
      let fam = self.load_family(login_id)
      if !fam.has_token(token) {
        // 幂等：已在族里就不动版本号
        fam.members.push(@port.FamilyMember::make(device, token, expire_at))
        fam.version += 1L
        self.save_family(login_id, fam)
      }
    }
    @port.MarkStatus(tokens, status, deadline) =>
      for token in tokens {
        self.revise_token(token, Some(status), deadline)
      }
    @port.RemoveTokens(login_id, tokens) => {
      self.remove(tokens.map((t : String) => self.keys.token(t)))
      let fam = self.load_family(login_id)
      let before = fam.members.length()
      fam.members = fam.members.filter((m : @port.FamilyMember) => {
        !tokens.contains(m.token)
      })
      if fam.members.length() != before {
        fam.version += 1L
      }
      self.save_family(login_id, fam)
    }
    @port.TouchExpire(tokens, expire_at) =>
      for token in tokens {
        self.revise_token(token, None, expire_at)
      }
    @port.PutRecord(key, payload, expire_at) =>
      self.put(key, payload, expire_at)
    @port.RemoveKeys(keys) => self.remove(keys)
  }
}

///|
pub fn MemoryStore::sweep_at(self : MemoryStore, now : Int64) -> Int {
  let dead = self.entries
    .to_array()
    .filter((pair : (String, Entry)) => is_expired(pair.1.expire_at, now))
    .map((pair : (String, Entry)) => pair.0)
  for key in dead {
    self.entries.remove(key)
  }
  // 反查族成员的到期不靠族键 TTL（族键本身可能还活着），这里一并回收
  let mut pruned = 0
  let family_entries = self.entries
    .to_array()
    .filter((pair : (String, Entry)) => pair.0.contains(":A:"))
  for (key, entry) in family_entries {
    let decoded = @port.FamilyRecord::decode(entry.payload)
    match decoded {
      None => ()
      Some(fam) => {
        let (kept, dropped) = fam.without_expired(now)
        if dropped > 0 {
          pruned += dropped
          if kept.is_empty() {
            self.entries.remove(key)
          } else {
            fam.members = kept
            entry.payload = fam.encode()
            entry.expire_at = fam.max_expire()
          }
        }
      }
    }
  }
  dead.length() + pruned
}

///|
pub impl @port.TokenStore for MemoryStore with fn get(self, key) {
  self.lookup(key)
}

///|
pub impl @port.TokenStore for MemoryStore with fn set(
  self,
  key,
  payload,
  expire_at,
) {
  self.put(key, payload, expire_at)
}

///|
pub impl @port.TokenStore for MemoryStore with fn del(self, keys) {
  self.remove(keys)
}

///|
pub impl @port.TokenStore for MemoryStore with fn get_and_del(self, key) {
  self.take(key)
}

///|
pub impl @port.TokenStore for MemoryStore with fn apply(self, patch) {
  self.apply_patch(patch)
}

///|
pub impl @port.TokenStore for MemoryStore with fn sweep(self, now) {
  self.sweep_at(now)
}

///|
pub extend MemoryStore with @port.TokenStore::{
  get,
  set,
  del,
  get_and_del,
  apply,
  sweep,
}
