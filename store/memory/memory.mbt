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
    @port.AddToken(login_id, device, token, expire_at, login_time) => {
      let fam = self.load_family(login_id)
      if !fam.has_token(token) {
        // 幂等：已在族里就不动版本号
        fam.members.push(
          @port.FamilyMember::make(device, token, expire_at, login_time),
        )
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
    @port.ForgetTokens(login_id, tokens) => {
      let fam = self.load_family(login_id)
      let before = fam.members.length()
      fam.members = fam.members.filter((m : @port.FamilyMember) => {
        !tokens.contains(m.token)
      })
      if fam.members.length() != before {
        fam.version += 1L
      }
      // 与 RemoveTokens 的唯一差别：不动 `T:` 键，墓碑要留着让对端读到精确原因
      self.save_family(login_id, fam)
    }
    @port.RefreshLogin(login_id, token, login_time) => {
      let fam = self.load_family(login_id)
      if fam.refresh_login(token, login_time) {
        // 移到队尾不增不减成员 ⇒ 不推版本号（不变量 3）
        self.save_family(login_id, fam)
      }
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
        let (alive_members, dropped) = fam.without_expired(now)
        // 族↔会话一致性收敛（契约 §4.1：成员是派生缓存，权威在 `T:`）：
        // 会话已经不在了 ⇒ 摘成员；会话还在但到期时刻不一致 ⇒ 以会话为准修，
        // 不修的话"续期只写 T、不写族"这条就会让族里的 e 永远停在签发时刻
        let kept : Array[@port.FamilyMember] = []
        let mut fixed = 0
        for m in alive_members {
          match self.entries.get(self.keys.token(m.token)) {
            None => pruned += 1
            Some(session_entry) =>
              match @port.SessionRecord::decode(session_entry.payload) {
                None => pruned += 1
                Some(session) => {
                  if session.expire_at != m.expire_at {
                    kept.push(
                      @port.FamilyMember::make(
                        m.device,
                        m.token,
                        session.expire_at,
                        m.login_time,
                      ),
                    )
                    fixed += 1
                  } else {
                    kept.push(m)
                  }
                }
              }
          }
        }
        let members_changed = kept.length() != fam.members.length()
        if dropped > 0 || members_changed || fixed > 0 {
          pruned += dropped
          if kept.is_empty() {
            self.entries.remove(key)
          } else {
            fam.members = kept
            // 版本号只随成员增删走（不变量 3）：单纯修正 e 不推版本
            if members_changed {
              fam.version += 1L
            }
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
/// 枚举排序：登录时刻**新**的在前，同刻按 token 字典序倒排。
/// 这条顺序就是 Redis 侧 `ZREVRANGEBYSCORE` 的返回顺序——两个后端必须一致，否则游标会漂。
fn listing_newer(a : @port.SessionListing, b : @port.SessionListing) -> Bool {
  a.login_time > b.login_time ||
  (a.login_time == b.login_time && a.token > b.token)
}

///|
/// 会话索引前缀，`list_sessions` 靠它从自有表里挑出 `T:` 条目
fn MemoryStore::token_prefix(self : MemoryStore) -> String {
  "\{self.keys.realm}:T:"
}

///|
/// 去掉键的固定头部拿到 token。逐字符数过去，不用 slice——realm/token 都可能含非 ASCII，
/// 字节数与字符数不一致时 slice 会切错位。
fn strip_head(s : String, head : String) -> String {
  let mut skip = 0
  for _ in head.iter() {
    skip += 1
  }
  let buf = StringBuilder()
  let mut i = 0
  for c in s.iter() {
    if i >= skip {
      buf.write_char(c)
    }
    i += 1
  }
  buf.to_string()
}

///|
/// 枚举活会话索引：按登录时刻反序翻页。条件只认精确的 login_id / device；
/// **判活不在这里做**——这一步返回的是索引级条目，取不到载荷的由 `get_many` 那一轮丢弃。
pub fn MemoryStore::scan_sessions(
  self : MemoryStore,
  filter : @port.SessionFilter,
  cursor : String,
  limit : Int,
) -> @port.SessionPage {
  let prefix = self.token_prefix()
  let size = @port.clamp_page_size(limit)
  let all : Array[@port.SessionListing] = []
  for (key, entry) in self.entries {
    if key.has_prefix(prefix) {
      match @port.SessionRecord::decode(entry.payload) {
        None => ()
        Some(record) => {
          let hit_login = filter.login_id.is_empty() ||
            record.login_id == filter.login_id
          let hit_device = filter.device.is_empty() ||
            record.device.id == filter.device
          if hit_login && hit_device {
            all.push(
              @port.SessionListing::make(
                strip_head(key, prefix),
                record.login_id,
                record.device.id,
                record.login_time,
                record.expire_at,
              ),
            )
          }
        }
      }
    }
  }
  // 插入排序：条目量级是"一个 realm 的在线数"，v1 内存版不为此写快排
  let mut sorted : Array[@port.SessionListing] = []
  for item in all {
    let mut pos = 0
    while pos < sorted.length() && listing_newer(sorted[pos], item) {
      pos += 1
    }
    let merged : Array[@port.SessionListing] = []
    let n = sorted.length()
    let mut i = 0
    while i < n {
      if i == pos {
        merged.push(item)
      }
      merged.push(sorted[i])
      i += 1
    }
    if pos >= n {
      merged.push(item)
    }
    sorted = merged
  }
  // 游标＝上一页最后一条的 (login_time, token)；只保留严格排在它之后的
  let after = match @port.parse_cursor(cursor) {
    None => (0L, "")
    Some(pair) => pair
  }
  let has_cursor = !cursor.is_empty()
  let items : Array[@port.SessionListing] = []
  for item in sorted {
    let keep = !has_cursor || sits_after(item, after)
    if keep && items.length() < size {
      items.push(item)
    }
  }
  let next_cursor = if items.length() < size {
    ""
  } else {
    @port.make_cursor(items[items.length() - 1])
  }
  @port.SessionPage::make(items, next_cursor)
}

///|
/// 游标之后的判定：只有登录时刻严格排在游标之后的才进下一页
/// （游标本身和它前面的都跳过——游标那条即使已被删也不影响，比较的是位置不是存在性）
fn sits_after(item : @port.SessionListing, cursor : (Int64, String)) -> Bool {
  item.login_time < cursor.0 ||
  (item.login_time == cursor.0 && item.token < cursor.1)
}

///|
/// 批量读：顺序与入参一致，缺失项为 `None`（含"已过期"，走的是与 `get` 同一套惰性判活）
pub fn MemoryStore::take_many(
  self : MemoryStore,
  keys : Array[String],
) -> Array[(String, String?)] {
  keys.map((key : String) => (key, self.lookup(key)))
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
pub impl @port.TokenStore for MemoryStore with fn get_many(self, keys) {
  self.take_many(keys)
}

///|
pub impl @port.TokenStore for MemoryStore with fn list_sessions(
  self,
  filter,
  cursor,
  limit,
) {
  self.scan_sessions(filter, cursor, limit)
}

///|
pub extend MemoryStore with @port.TokenStore::{
  get,
  set,
  del,
  get_and_del,
  apply,
  sweep,
  get_many,
  list_sessions,
}
