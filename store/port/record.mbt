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
}

///|
pub fn FamilyMember::make(
  device : Device,
  token : String,
  expire_at : Int64,
) -> FamilyMember {
  let m : FamilyMember = { device, token, expire_at, }
  m
}

///|
pub fn FamilyMember::same(self : FamilyMember, other : FamilyMember) -> Bool {
  self.token == other.token &&
  self.device.id == other.device.id &&
  self.expire_at == other.expire_at
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
