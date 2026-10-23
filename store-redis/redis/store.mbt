///|
/// Redis 适配器：moon-token 的第二个真后端（`store-file` 之后）。
/// 存在的理由是**多实例共享会话**——内存版与文件版都只服务单进程。
///
/// 物理映射（键位与线格式一律取自共享内核，适配器不发明字段名）：
/// - `{realm}:T:{token}` → STRING，`PXAT` 到传入的 `expire_at`
/// - `{realm}:A:{login_id}` → STRING（整条 `FamilyRecord` 线格式），**改族必须 CAS**
/// - `{realm}:Z` → ZSET，member=token、score=登录时刻，是 `list_sessions` 的枚举源
/// - `{realm}:S:` / `R:` / `D:` / `P:` → 普通 STRING，走同一套 `set`/`get`/`del`
///
/// 三条与参考实现（`store/memory`）对齐的硬口径，都在测试里钉着：
/// ① 惰性过期分两档——`T:` 键的 TTL 已经是 `expire_at + kick_grace`（加窗收在
///    `TokenConfig::key_expire_at`，core 传给 store 的就是加过窗的值），
///    所以适配器**绝不再加一次**；"过了签发时效但还在保留窗内"照旧返回载荷，
///    让裁决层能报 `SessionExpired` 而不是塌成 `UnknownToken`。
/// ② `apply` 的每个变体都幂等，`ForgetTokens` 与 `RemoveTokens` 的差别只在留不留 `T:` 键，
///    `RefreshLogin` 移回队尾刷 `lt` 但不推版本号。
/// ③ `list_sessions` 的序与游标和内存版逐字同尺（登录时刻新在前，同刻按 token 倒排）。
pub(all) struct RedisStore {
  client : @redis_client.RedisClient
  keys : @port.KeySpace
}

///|
/// 族键的乐观并发：整块比对再写。`ARGV[1]='0'` 表示"预期这键还不存在"，
/// `'1'` 表示"预期它等于 `ARGV[2]`"；不匹配就返回 -1，由调用方重读重试。
/// 比对整块载荷而不是比对 `ver` 字段：载荷是转义过的线格式，比对字节最没有歧义。
let family_cas_script : String = "local cur = redis.call('GET', KEYS[1]) if ARGV[1] == '0' then if cur then return -1 end else if cur ~= ARGV[2] then return -1 end end redis.call('SET', KEYS[1], ARGV[3]) if ARGV[4] ~= '0' then redis.call('PEXPIREAT', KEYS[1], ARGV[4]) end return 1"

///|
/// 原子取删。低版本 Redis（我们部署的 5.0.4）没有 `GETDEL`（6.2+ 才有），
/// 所以两台都走同一条 Lua——判据不能依赖服务端版本。
let get_and_del_script : String = "local v = redis.call('GET', KEYS[1]) if v then redis.call('DEL', KEYS[1]) end return v"

///|
/// 族 CAS 的最大重试次数。并发登录在同账号上是"几台设备各写一次"，个位数足够；
/// 超出就投端口错误，绝不静默整块覆盖（那会丢别的设备刚写的成员）。
let cas_retries : Int = 8

///|
/// MGET 的分块大小：在线列表一次可能取回几百个 token，一帧发出去会让服务端
/// 与客户端都吃一次超大请求。
let mget_chunk : Int = 200

///|
/// 建立连接。`password` 空串＝不发 `AUTH`（发了会被无鉴权的服务端当成错误），
/// `db` 0 也照发 `SELECT`，与内存版"realm 决定隔离"的口径一致。
pub async fn RedisStore::open(
  realm : String,
  host : String,
  port? : Int = 6379,
  password? : String = "",
  db? : Int = 0,
) -> RedisStore raise @port.TokenError {
  let client = try {
    if password.is_empty() {
      Ok(@redis_client.connect(host, port~, db~))
    } else {
      Ok(@redis_client.connect(host, port~, password~, db~))
    }
  } catch {
    @redis_client.ConnectError::AuthFailed(msg) => Err(msg)
    @redis_client.ConnectError::SelectFailed(msg) => Err(msg)
    _ => Err("socket setup failed")
  }
  match client {
    Ok(c) => { client: c, keys: @port.KeySpace::of(realm), }
    Err(msg) =>
      raise @port.Store(
        "redis connect to \{host}:\{port.to_string()} failed: \{msg}",
      )
  }
}

///|
pub fn RedisStore::close(self : RedisStore) -> Unit {
  self.client.close()
}

///|
pub async fn RedisStore::ask(
  self : RedisStore,
  args : Array[String],
) -> @redis_client.RedisValue raise @port.TokenError {
  // `send` 带一个连接层的错误效果（读帧中途断流），端口契约里没有这一档，
  // 所以在这里收拢成 `Store`：适配器对上游暴露的失败词汇只有共享内核那一种。
  let sent = Ok(self.client.send(args)) catch {
    _ => Err("transport error while sending \{args[0]}")
  }
  match sent {
    Err(msg) => raise @port.Store(msg)
    Ok(raw) =>
      match raw {
        @redis_client.RedisValue::Error(msg) =>
          raise @port.Store("\{args[0]} failed: \{msg}")
        other => other
      }
  }
}

///|
fn text_of(reply : @redis_client.RedisValue) -> String? {
  match reply {
    @redis_client.RedisValue::BulkString(Some(v)) => Some(v)
    @redis_client.RedisValue::SimpleString(v) => Some(v)
    _ => None
  }
}

///|
fn int_of(reply : @redis_client.RedisValue) -> Int64? {
  match reply {
    @redis_client.RedisValue::Integer(v) => Some(v.to_int64())
    // EXISTS / TTL 这类回复在个别服务端版本上是简单字符串，取不到就当 0
    _ => None
  }
}

///|
fn rows_of(reply : @redis_client.RedisValue) -> Array[@redis_client.RedisValue] {
  match reply {
    @redis_client.RedisValue::Array(items) => items
    _ => []
  }
}

///|
async fn RedisStore::read_raw(
  self : RedisStore,
  key : String,
) -> String? raise @port.TokenError {
  text_of(self.ask(["GET", key]))
}

///|
/// 写一个键。`expire_at <= 0` 是不不过期的持久键（内存版同款口径）。
async fn RedisStore::write_raw(
  self : RedisStore,
  key : String,
  payload : String,
  expire_at : Int64,
) -> Unit raise @port.TokenError {
  if expire_at > 0L {
    let _ = self.ask(["SET", key, payload])
    // 绝对到期点要分两步：`SET ... PXAT` 是 Redis 6.0+ 才认的，我们部署的 5.0.4 直接
    // `ERR syntax error`，而独立的 `PEXPIREAT`（2.6+）两台都通。
    // PEXPIREAT 没成功就把刚写进去的键删掉——留一个永不过期的会话键，
    // 等于把"过期即回收"这条契约悄悄换成"泄漏"，而且不会有任何用例变红。
    let stamped = int_of(self.ask(["PEXPIREAT", key, expire_at.to_string()]))
    match stamped {
      Some(1L) => ()
      _ => {
        let _ = self.delete_keys([key])
        raise @port.Store("cannot set expiry on \{key}")
      }
    }
  } else {
    let _ = self.ask(["SET", key, payload])
  }
}

///|
async fn RedisStore::delete_keys(
  self : RedisStore,
  keys : Array[String],
) -> Unit raise @port.TokenError {
  if !keys.is_empty() {
    let _ = self.ask(["DEL", ..keys])
  }
}

///|
/// 批量读：一次 MGET 拿多个键，缺失项是 `BulkString(None)`（**不是**字符串 "null"，
/// 那是 typed `to_array` 的渲染，这里刻意不走它）。顺序与入参一致。
async fn RedisStore::read_many(
  self : RedisStore,
  keys : Array[String],
) -> Array[(String, String?)] raise @port.TokenError {
  let out : Array[(String, String?)] = []
  let total = keys.length()
  let mut start = 0
  while start < total {
    let stop = if start + mget_chunk > total {
      total
    } else {
      start + mget_chunk
    }
    let slice : Array[String] = []
    for i in start..<stop {
      slice.push(keys[i])
    }
    let items = rows_of(self.ask(["MGET", ..slice]))
    for i in 0..<slice.length() {
      let value = if i < items.length() { text_of(items[i]) } else { None }
      out.push((slice[i], value))
    }
    start = stop
  }
  out
}

///|
/// 按模式扫键（只服务 `sweep` 这种维护动作，端口层不暴露裸扫描）。
/// `SCAN` 的回复是 `[游标, [键表]]` 那层嵌套，typed `scan` 啃不动，这里自己解。
pub async fn RedisStore::scan_keys(
  self : RedisStore,
  pattern : String,
) -> Array[String] raise @port.TokenError {
  let found : Array[String] = []
  let mut cursor = "0"
  let mut rounds = 0
  while true {
    let parts = rows_of(
      self.ask(["SCAN", cursor, "MATCH", pattern, "COUNT", "500"]),
    )
    if parts.length() < 2 {
      break
    }
    let next = text_of(parts[0]).unwrap_or("0")
    for item in rows_of(parts[1]) {
      match text_of(item) {
        Some(key) => found.push(key)
        None => ()
      }
    }
    rounds += 1
    if next == "0" || rounds > 2000 {
      break
    }
    cursor = next
  }
  found
}

///|
async fn RedisStore::index_members(
  self : RedisStore,
) -> Array[String] raise @port.TokenError {
  let tokens : Array[String] = []
  for
    item in rows_of(self.ask(["ZRANGE", self.keys.session_index(), "0", "-1"])) {
    match text_of(item) {
      Some(token) => tokens.push(token)
      None => ()
    }
  }
  tokens
}

///|
/// 族记录的 CAS 更新：读现值→纯函数改→整块比对写回，失败重读重试。
/// `edit` 返回"是否真的需要落盘"，返回 `false` 就是空操作（幂等性靠它）。
async fn RedisStore::update_family(
  self : RedisStore,
  login_id : String,
  edit : (@port.FamilyRecord) -> Bool,
) -> Unit raise @port.TokenError {
  let key = self.keys.family(login_id)
  let mut attempt = 0
  while attempt < cas_retries {
    attempt += 1
    let current = self.read_raw(key)
    let record = match current {
      None => @port.FamilyRecord::empty(login_id)
      Some(blob) =>
        match @port.FamilyRecord::decode(blob) {
          // 解不开就按空族重建——与内存版 `load_family` 同一判据，两边才不会各修一套
          None => @port.FamilyRecord::empty(login_id)
          Some(decoded) => decoded
        }
    }
    if edit(record) {
      let ttl = record.max_expire()
      let expect_mode = match current {
        None => "0"
        Some(_) => "1"
      }
      let expect_blob = match current {
        None => ""
        Some(blob) => blob
      }
      let reply = self.ask([
        "EVAL",
        family_cas_script,
        "1",
        key,
        expect_mode,
        expect_blob,
        record.encode(),
        ttl.to_string(),
      ])
      match int_of(reply) {
        Some(1L) => return
        Some(_) => ()
        None =>
          raise @port.Store("family CAS reply is not an integer for \{key}")
      }
    } else {
      return
    }
  }
  raise @port.Store("family CAS retries exhausted for \{key}")
}

///|
/// 族成员的纯函数改写：摘掉 `tokens` 里的成员，成员集合真变了才推版本号
pub fn family_drop(record : @port.FamilyRecord, tokens : Array[String]) -> Bool {
  let before = record.members.length()
  record.members = record.members.filter((m : @port.FamilyMember) => {
    !tokens.contains(m.token)
  })
  let changed = record.members.length() != before
  if changed {
    record.version += 1L
  }
  changed
}

///|
async fn RedisStore::index_add(
  self : RedisStore,
  token : String,
  login_time : Int64,
) -> Unit raise @port.TokenError {
  let _ = self.ask([
    "ZADD",
    self.keys.session_index(),
    login_time.to_string(),
    token,
  ])
}

///|
async fn RedisStore::index_drop(
  self : RedisStore,
  tokens : Array[String],
) -> Unit raise @port.TokenError {
  if !tokens.is_empty() {
    let _ = self.ask(["ZREM", self.keys.session_index(), ..tokens])
  }
}

///|
/// 改写 `T:` 记录的状态与到期时刻（`None` 表示只搬到期点、不动状态）
async fn RedisStore::revise_token(
  self : RedisStore,
  token : String,
  status : @port.SessionStatus?,
  logical_expire_at : Int64,
  key_expire_at : Int64,
) -> Unit raise @port.TokenError {
  let key = self.keys.token(token)
  match self.read_raw(key) {
    None => ()
    Some(blob) =>
      match @port.SessionRecord::decode(blob) {
        None => ()
        Some(record) => {
          match status {
            Some(s) => record.status = s
            None => ()
          }
          record.expire_at = logical_expire_at
          let _ = self.write_raw(key, record.encode(), key_expire_at)
        }
      }
  }
}

///|
/// 令牌前缀，`RemoveKeys` 靠它认出哪些键是会话、顺带收索引
fn RedisStore::token_prefix(self : RedisStore) -> String {
  self.keys.token("")
}

///|
/// 去掉固定头部取 token。逐字符数过去而不是按字节切片——realm/token 都可能含非 ASCII，
/// 字节数与字符数不一致时切片会切错位（内存版 `strip_head` 同一把尺子）。
pub fn strip_head(text : String, head : String) -> String {
  let skip = head.length()
  let buf = StringBuilder()
  let mut i = 0
  for c in text.iter() {
    if i >= skip {
      buf.write_char(c)
    }
    i += 1
  }
  buf.to_string()
}

///|
/// 登录序比较，与内存版 `listing_newer` 逐字同尺：登录时刻新的在前，同刻按 token 字典序倒排。
pub fn listing_newer(
  a : @port.SessionListing,
  b : @port.SessionListing,
) -> Bool {
  a.login_time > b.login_time ||
  (a.login_time == b.login_time && a.token > b.token)
}

///|
/// 游标之后的判定，与内存版 `sits_after` 同尺
pub fn sits_after(
  item : @port.SessionListing,
  cursor : (Int64, String),
) -> Bool {
  item.login_time < cursor.0 ||
  (item.login_time == cursor.0 && item.token < cursor.1)
}

///|
/// 按 `listing_newer` 把条目排成"新在前"。与内存版同一套插入排序：
/// 在线规模是"一个 realm 的会话数"，这里要的是**与参考实现逐字同序**，不是性能。
pub fn sort_listings(
  items : Array[@port.SessionListing],
) -> Array[@port.SessionListing] {
  let mut sorted : Array[@port.SessionListing] = []
  for item in items {
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
  sorted
}

///|
pub async fn RedisStore::scan_sessions(
  self : RedisStore,
  filter : @port.SessionFilter,
  cursor : String,
  limit : Int,
) -> @port.SessionPage raise @port.TokenError {
  let size = @port.clamp_page_size(limit)
  let prefix = self.token_prefix()
  let tokens = self.index_members()
  let keys : Array[String] = []
  for token in tokens {
    keys.push(prefix + token)
  }
  let pairs = self.read_many(keys)
  let after = match @port.parse_cursor(cursor) {
    None => (0L, "")
    Some(pair) => pair
  }
  let has_cursor = !cursor.is_empty()
  let all : Array[@port.SessionListing] = []
  for (key, payload) in pairs {
    match payload {
      None => ()
      Some(blob) =>
        match @port.SessionRecord::decode(blob) {
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
  let sorted = sort_listings(all)
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
pub async fn RedisStore::take(
  self : RedisStore,
  key : String,
) -> String? raise @port.TokenError {
  text_of(self.ask(["EVAL", get_and_del_script, "1", key]))
}

///|
pub async fn RedisStore::sweep_at(
  self : RedisStore,
  now : Int64,
) -> Int raise @port.TokenError {
  let mut cleaned = 0
  // ① 族：过期成员回收，成员对应的 `T:` 已不在也回收；
  //    会话还在但 `e` 与族里不一致时以会话为准修（续期只写 `T:` 不写族会留下这种偏差）。
  //    版本号只随成员增删走，单纯修 `e` 不推。
  let family_pattern = self.keys.family("") + "*"
  for fkey in self.scan_keys(family_pattern) {
    match self.read_raw(fkey) {
      None => ()
      Some(blob) =>
        match @port.FamilyRecord::decode(blob) {
          None => ()
          Some(record) => {
            let (alive, dropped) = record.without_expired(now)
            let session_keys : Array[String] = []
            for m in alive {
              session_keys.push(self.keys.token(m.token))
            }
            let sessions = self.read_many(session_keys)
            let kept : Array[@port.FamilyMember] = []
            let mut pruned = 0
            let mut fixed = 0
            let mut slot = 0
            for m in alive {
              let payload = if slot < sessions.length() {
                sessions[slot].1
              } else {
                None
              }
              slot += 1
              match payload {
                None => pruned += 1
                Some(session_blob) =>
                  match @port.SessionRecord::decode(session_blob) {
                    None => pruned += 1
                    Some(session) =>
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
            let membership_changed = kept.length() != record.members.length()
            if dropped > 0 || membership_changed || fixed > 0 {
              cleaned += dropped
              cleaned += pruned
              if kept.is_empty() {
                let _ = self.delete_keys([fkey])
              } else {
                record.members = kept
                if membership_changed {
                  record.version += 1L
                }
                let ttl = record.max_expire()
                let expect_mode = "1"
                let reply = self.ask([
                  "EVAL",
                  family_cas_script,
                  "1",
                  fkey,
                  expect_mode,
                  blob,
                  record.encode(),
                  ttl.to_string(),
                ])
                match int_of(reply) {
                  Some(1L) => ()
                  // 族正被并发改写：这一轮跳过，下一轮 sweep 再收（不整块覆盖别人的写）
                  _ => ()
                }
              }
            }
          }
        }
    }
  }
  // ② 活会话索引：`T:` 已不存在的成员收掉。这一步是"索引不裁决"的另一半——
  //    留着脏成员只会让枚举多读一次空载荷，但键数会单调增长。
  let tokens = self.index_members()
  let keys : Array[String] = []
  for token in tokens {
    keys.push(self.keys.token(token))
  }
  let stale : Array[String] = []
  let pairs = self.read_many(keys)
  let mut idx = 0
  for (_, payload) in pairs {
    // 载荷取不到，或取到了却解不成会话记录（索引指向垃圾）⇒ 都算脏成员
    let dead = match payload {
      None => true
      Some(blob) => @port.SessionRecord::decode(blob) is None
    }
    if dead {
      stale.push(tokens[idx])
    }
    idx += 1
  }
  let _ = self.index_drop(stale)
  cleaned + stale.length()
}

///|
pub async fn RedisStore::apply_patch(
  self : RedisStore,
  patch : @port.FamilyPatch,
) -> Unit raise @port.TokenError {
  match patch {
    @port.AddToken(login_id, device, token, expire_at, login_time) => {
      let _ = self.update_family(login_id, (record : @port.FamilyRecord) => {
        if record.has_token(token) {
          // 已在族里就不动版本号：重复投递必须无副作用
          false
        } else {
          record.members.push(
            @port.FamilyMember::make(device, token, expire_at, login_time),
          )
          record.version += 1L
          true
        }
      })
      let _ = self.index_add(token, login_time)
    }
    @port.MarkStatus(tokens, status, deadline) =>
      for token in tokens {
        let _ = self.revise_token(token, Some(status), deadline, deadline)
      }
    @port.RemoveTokens(login_id, tokens) => {
      let session_keys : Array[String] = []
      for token in tokens {
        session_keys.push(self.keys.token(token))
      }
      let _ = self.delete_keys(session_keys)
      let _ = self.index_drop(tokens)
      let _ = self.update_family(login_id, (record : @port.FamilyRecord) => {
        family_drop(record, tokens)
      })
    }
    @port.ForgetTokens(login_id, tokens) => {
      // 与 RemoveTokens 的唯一差别：不动 `T:` 键，也不动索引——
      // 墓碑要留着让对端读到精确原因，而内存版枚举的就是"还在的 `T:` 键"这一集
      let _ = self.update_family(login_id, (record : @port.FamilyRecord) => {
        family_drop(record, tokens)
      })
    }
    @port.RefreshLogin(login_id, token, login_time) => {
      let _ = self.update_family(login_id, (record : @port.FamilyRecord) => {
        record.refresh_login(token, login_time)
      })
      let _ = self.index_add(token, login_time)
    }
    @port.TouchExpire(
      login_id,
      device,
      token,
      logical_expire_at,
      login_time,
      key_expire_at
    ) => {
      let _ = self.revise_token(token, None, logical_expire_at, key_expire_at)
      let _ = self.update_family(login_id, (record : @port.FamilyRecord) => {
        record.touch_expire(device, token, logical_expire_at, login_time)
      })
      // 族里原本没有这成员时，`touch_expire` 会补上并按"增"推版本号；索引同样补一次
      let _ = self.index_add(token, login_time)
    }
    @port.PutRecord(key, payload, expire_at) => {
      let _ = self.write_raw(key, payload, expire_at)
    }
    @port.RemoveKeys(keys) => {
      let prefix = self.token_prefix()
      let dropped : Array[String] = []
      for key in keys {
        if key.has_prefix(prefix) {
          dropped.push(strip_head(key, prefix))
        }
      }
      let _ = self.delete_keys(keys)
      let _ = self.index_drop(dropped)
    }
  }
}

///|
pub impl @port.TokenStore for RedisStore with fn get(self, key) {
  self.read_raw(key)
}

///|
pub impl @port.TokenStore for RedisStore with fn set(
  self,
  key,
  payload,
  expire_at,
) {
  self.write_raw(key, payload, expire_at)
}

///|
pub impl @port.TokenStore for RedisStore with fn del(self, keys) {
  self.delete_keys(keys)
}

///|
pub impl @port.TokenStore for RedisStore with fn get_and_del(self, key) {
  self.take(key)
}

///|
pub impl @port.TokenStore for RedisStore with fn apply(self, patch) {
  self.apply_patch(patch)
}

///|
pub impl @port.TokenStore for RedisStore with fn sweep(self, now) {
  self.sweep_at(now)
}

///|
pub impl @port.TokenStore for RedisStore with fn get_many(self, keys) {
  self.read_many(keys)
}

///|
pub impl @port.TokenStore for RedisStore with fn list_sessions(
  self,
  filter,
  cursor,
  limit,
) {
  self.scan_sessions(filter, cursor, limit)
}

///|
pub extend RedisStore with @port.TokenStore::{
  get,
  set,
  del,
  get_and_del,
  apply,
  sweep,
  get_many,
  list_sessions,
}
