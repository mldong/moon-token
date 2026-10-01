///|
/// 统一错误模型属于**共享内核**（store/port）而不是 core：
/// 仓储端口要抛它，应用层也要抛它——若把它放 core 就会形成 core↔store 环，
/// 若端口另立一套错误类型则应用层每次调用都要做效果转换。故一处一份词汇表。
/// 变体名与 `SessionStatus` 同包共存，故刻意不重名（Kicked→KickedOut 等）。

///|
/// 未登录的精确原因——"被踢"和"过期"绝不能都报成笼统未登录，这是本库的核心卖点。
pub(all) enum NotLoginReason {
  AbsentToken
  UnknownToken
  SessionExpired
  ActiveTimeout
  KickedOut
  SupersededByLogin
  RefreshInvalid
}

///|
pub fn NotLoginReason::code(self : NotLoginReason) -> Int {
  match self {
    AbsentToken => 1
    UnknownToken => 2
    SessionExpired => 3
    ActiveTimeout => 4
    KickedOut => 5
    SupersededByLogin => 6
    RefreshInvalid => 7
  }
}

///|
pub fn NotLoginReason::label(self : NotLoginReason) -> String {
  match self {
    AbsentToken => "AbsentToken"
    UnknownToken => "UnknownToken"
    SessionExpired => "SessionExpired"
    ActiveTimeout => "ActiveTimeout"
    KickedOut => "KickedOut"
    SupersededByLogin => "SupersededByLogin"
    RefreshInvalid => "RefreshInvalid"
  }
}

///|
/// core 与 guard 贯穿使用；web 层（v2 防腐层）负责映射成响应码。
/// `Store(String)` 是后端 IO 失败的通道（v2 Redis/moondb 用它，内存档永不触发）。
pub(all) suberror TokenError {
  NotLogin(NotLoginReason)
  NotPermission(String)
  NotRole(String)
  Disabled(String, Int64)
  InvalidInput(String)
  Store(String)
}

///|
pub fn TokenError::message(self : TokenError) -> String {
  match self {
    NotLogin(reason) => "not login: \{reason.label()}"
    NotPermission(p) => "no permission: \{p}"
    NotRole(r) => "no role: \{r}"
    Disabled(reason, until) => "disabled until \{until.to_string()}: \{reason}"
    InvalidInput(msg) => "invalid input: \{msg}"
    Store(msg) => "store error: \{msg}"
  }
}

///|
/// 供测试与上层精确断言（负向用例只断言"报错了"是不够的）
pub fn TokenError::not_login_reason(self : TokenError) -> NotLoginReason? {
  match self {
    NotLogin(reason) => Some(reason)
    _ => None
  }
}

///|
/// 封禁判定单点：`D:` 记录的载荷形状也归共享内核，避免适配器与领域各发明一套字段名
pub(all) struct BanRecord {
  until : Int64
  reason : String
}

///|
pub fn BanRecord::make(until : Int64, reason : String) -> BanRecord {
  let b : BanRecord = { until, reason, }
  b
}

///|
pub fn BanRecord::encode(self : BanRecord) -> String {
  encode_record([("until", self.until.to_string()), ("reason", self.reason)])
}

///|
pub fn BanRecord::decode(text : String) -> BanRecord? {
  match decode_record(text) {
    None => None
    Some(f) =>
      Some(
        BanRecord::make(
          record_field_int64(f, "until"),
          record_field_or(f, "reason", ""),
        ),
      )
  }
}

///|
/// refresh 记录载荷（`R:` 键）：绑回原 access token 才能做到"旧对同时失效"
pub(all) struct RefreshRecord {
  login_id : String
  device_id : String
  access_token : String
}

///|
pub fn RefreshRecord::make(
  login_id : String,
  device_id : String,
  access_token : String,
) -> RefreshRecord {
  let r : RefreshRecord = { login_id, device_id, access_token, }
  r
}

///|
pub fn RefreshRecord::encode(self : RefreshRecord) -> String {
  encode_record([
    ("login", self.login_id),
    ("dev", self.device_id),
    ("access", self.access_token),
  ])
}

///|
pub fn RefreshRecord::decode(text : String) -> RefreshRecord? {
  match decode_record(text) {
    None => None
    Some(f) => {
      let login_id = record_field_or(f, "login", "")
      if login_id.is_empty() {
        None
      } else {
        Some(
          RefreshRecord::make(
            login_id,
            record_field_or(f, "dev", DEFAULT_DEVICE_ID),
            record_field_or(f, "access", ""),
          ),
        )
      }
    }
  }
}

///|
/// 账号级会话载荷（`S:` 键）：跨 token 共享的业务附加态
pub(all) struct AccountSessionRecord {
  mut login_id : String
  mut attrs : Map[String, String]
}

///|
pub fn AccountSessionRecord::make(login_id : String) -> AccountSessionRecord {
  let r : AccountSessionRecord = { login_id, attrs: Map([]), }
  r
}

///|
pub fn AccountSessionRecord::encode(self : AccountSessionRecord) -> String {
  encode_record([
    ("login", self.login_id),
    ("attrs", encode_record(self.attrs.to_array())),
  ])
}

///|
pub fn AccountSessionRecord::decode(text : String) -> AccountSessionRecord? {
  match decode_record(text) {
    None => None
    Some(f) => {
      let login_id = record_field_or(f, "login", "")
      if login_id.is_empty() {
        None
      } else {
        let attrs = match decode_record(record_field_or(f, "attrs", "v=1")) {
          None => Map([])
          Some(map) => map
        }
        let r : AccountSessionRecord = { login_id, attrs, }
        Some(r)
      }
    }
  }
}
