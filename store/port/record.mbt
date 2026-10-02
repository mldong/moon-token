///|
/// 会话记录（线格式）：`T:` 键的 payload 形状由端口定义，
/// 内存适配器与 core 领域模型共用同一份编解码，避免"两实现各自发明字段名"。
pub(all) struct SessionRecord {
  mut login_id : String
  mut device : Device
  mut login_time : Int64
  mut expire_at : Int64
  mut last_active : Int64
  mut status : SessionStatus
  mut extra : Map[String, String]
  mut refresh_token : String
}

///|
pub fn SessionRecord::make(
  login_id : String,
  device : Device,
  at : Int64,
  expire_at : Int64,
) -> SessionRecord {
  let record : SessionRecord = {
    login_id,
    device,
    login_time: at,
    expire_at,
    last_active: at,
    status: Active,
    extra: Map([]),
    refresh_token: "",
  }
  record
}

///|
pub fn SessionRecord::encode(self : SessionRecord) -> String {
  let extra_blob = encode_record(self.extra.to_array())
  encode_record([
    ("login", self.login_id),
    ("dev", self.device.id),
    ("lt", self.login_time.to_string()),
    ("exp", self.expire_at.to_string()),
    ("la", self.last_active.to_string()),
    ("st", self.status.to_code()),
    ("refresh", self.refresh_token),
    ("extra", extra_blob),
  ])
}

///|
pub fn SessionRecord::decode(text : String) -> SessionRecord? {
  match decode_record(text) {
    None => None
    Some(f) => {
      let login_id = record_field_or(f, "login", "")
      match SessionStatus::of_code(record_field_or(f, "st", "0")) {
        None => None
        Some(status) =>
          if login_id.is_empty() {
            None
          } else {
            let extra = match
              decode_record(record_field_or(f, "extra", "v=1")) {
              None => Map([])
              Some(map) => map
            }
            let record : SessionRecord = {
              login_id,
              device: Device::of(record_field_or(f, "dev", DEFAULT_DEVICE_ID)),
              login_time: record_field_int64(f, "lt"),
              expire_at: record_field_int64(f, "exp"),
              last_active: record_field_int64(f, "la"),
              status,
              extra,
              refresh_token: record_field_or(f, "refresh", ""),
            }
            Some(record)
          }
      }
    }
  }
}

///|
/// 反查族成员
pub(all) struct FamilyMember {
  device : Device
  token : String
  expire_at : Int64
  /// 登录时刻（ms）。`max_sessions` 的"先进先出"按它定序——载体（Redis HASH / SQL 成员表）
  /// 不保证任何顺序，所以登录时刻必须显式存一份，不能靠"追加序"或拿 `expire_at` 顶替。
  login_time : Int64
}

///|
pub fn FamilyMember::make(
  device : Device,
  token : String,
  expire_at : Int64,
  login_time : Int64,
) -> FamilyMember {
  let m : FamilyMember = { device, token, expire_at, login_time, }
  m
}

///|
pub fn FamilyMember::same(self : FamilyMember, other : FamilyMember) -> Bool {
  self.token == other.token &&
  self.device.id == other.device.id &&
  self.expire_at == other.expire_at &&
  self.login_time == other.login_time
}

///|
pub fn FamilyMember::alive(self : FamilyMember, now : Int64) -> Bool {
  self.expire_at <= 0L || self.expire_at > now
}

///|
/// 反查族记录（`A:` 键的 payload）
pub(all) struct FamilyRecord {
  mut login_id : String
  mut version : Int64
  mut members : Array[FamilyMember]
}

///|
pub fn FamilyRecord::empty(login_id : String) -> FamilyRecord {
  let record : FamilyRecord = { login_id, version: 0L, members: [], }
  record
}

///|
pub fn FamilyRecord::make(
  login_id : String,
  version : Int64,
  members : Array[FamilyMember],
) -> FamilyRecord {
  let record : FamilyRecord = { login_id, version, members, }
  record
}

///|
pub fn FamilyRecord::encode(self : FamilyRecord) -> String {
  let items = self.members.map((m : FamilyMember) => {
    encode_record([
      ("d", m.device.id),
      ("t", m.token),
      ("e", m.expire_at.to_string()),
      ("lt", m.login_time.to_string()),
    ])
  })
  encode_record([
    ("login", self.login_id),
    ("ver", self.version.to_string()),
    ("members", encode_list(items)),
  ])
}

///|
pub fn FamilyRecord::decode(text : String) -> FamilyRecord? {
  match decode_record(text) {
    None => None
    Some(f) => {
      let login_id = record_field_or(f, "login", "")
      if login_id.is_empty() {
        None
      } else {
        let members = decode_list(record_field_or(f, "members", "")).filter_map(item => {
            match decode_record(item) {
              None => None
              Some(mf) => {
                let token = record_field_or(mf, "t", "")
                if token.is_empty() {
                  None
                } else {
                  Some(
                    FamilyMember::make(
                      Device::of(record_field_or(mf, "d", DEFAULT_DEVICE_ID)),
                      token,
                      record_field_int64(mf, "e"),
                      // 旧串没有 lt：解成 0＝"登录时刻未知"，在淘汰排序里天然排最前，
                      // 也就是升级前签发的会话会先被上限剔掉——比反过来要安全
                      record_field_int64(mf, "lt"),
                    ),
                  )
                }
              }
            }
          },
        )
        Some(
          FamilyRecord::make(login_id, record_field_int64(f, "ver"), members),
        )
      }
    }
  }
}

///|
pub fn FamilyRecord::has_token(self : FamilyRecord, token : String) -> Bool {
  let mut found = false
  for m in self.members {
    if m.token == token {
      found = true
    }
  }
  found
}

///|
pub fn FamilyRecord::find_device(
  self : FamilyRecord,
  device : Device,
) -> FamilyMember? {
  let mut found : FamilyMember? = None
  for m in self.members {
    if m.device.id == device.id && found is None {
      found = Some(m)
    }
  }
  found
}

///|
pub fn FamilyRecord::tokens_of_device(
  self : FamilyRecord,
  device : Device,
) -> Array[String] {
  self.members
  .filter((m : FamilyMember) => m.device.id == device.id)
  .map((m : FamilyMember) => m.token)
}

///|
pub fn FamilyRecord::all_tokens(self : FamilyRecord) -> Array[String] {
  self.members.map((m : FamilyMember) => m.token)
}

///|
/// 去掉已过期成员，返回（保留列表，清掉的条数）
pub fn FamilyRecord::without_expired(
  self : FamilyRecord,
  now : Int64,
) -> (Array[FamilyMember], Int) {
  let kept = self.members.filter((m : FamilyMember) => m.alive(now))
  (kept, self.members.length() - kept.length())
}

///|
pub fn FamilyRecord::max_expire(self : FamilyRecord) -> Int64 {
  let mut best = 0L
  for m in self.members {
    if m.expire_at > best {
      best = m.expire_at
    }
  }
  best
}

///|
/// 登录序比较：先比登录时刻，同刻用 token 字典序兜底——否则"谁最老"在两个后端上会各自抖。
fn login_older(a : FamilyMember, b : FamilyMember) -> Bool {
  a.login_time < b.login_time ||
  (a.login_time == b.login_time && a.token < b.token)
}

///|
/// 活成员里按**登录时刻升序**取前 k 个 token（`max_sessions` 的先进先出淘汰用）。
/// 显式比 `login_time` 而不是吃数组顺序：Redis HASH 字段无序、SQL 成员表无天然行序，
/// 三个后端必须对"谁最老"给出同一个答案。
pub fn FamilyRecord::oldest_tokens(
  self : FamilyRecord,
  k : Int,
  now : Int64,
) -> Array[String] {
  let live = self.members.filter((m : FamilyMember) => m.alive(now))
  let taken : Array[Bool] = live.map((_ : FamilyMember) => false)
  let out : Array[String] = []
  let rounds = if k < live.length() {
    k
  } else {
    live.length()
  }
  let mut round = 0
  while round < rounds {
    let mut best = -1
    let mut j = 0
    while j < live.length() {
      if !taken[j] {
        if best < 0 {
          best = j
        } else if login_older(live[j], live[best]) {
          best = j
        }
      }
      j += 1
    }
    if best < 0 {
      round = rounds
    } else {
      taken[best] = true
      out.push(live[best].token)
      round += 1
    }
  }
  out
}
