///|
/// 未登录的精确原因——"被踢"和"过期"绝不能都报成笼统的未登录，
/// 这是本库的核心卖点之一（13 栈同款口径）。
pub(all) enum NotLoginReason {
  NoToken
  InvalidToken
  Expired
  Kicked
  Superseded
  RefreshInvalid
}

///|
pub fn NotLoginReason::code(self : NotLoginReason) -> Int {
  match self {
    NoToken => 1
    InvalidToken => 2
    Expired => 3
    Kicked => 4
    Superseded => 5
    RefreshInvalid => 6
  }
}

///|
pub fn NotLoginReason::label(self : NotLoginReason) -> String {
  match self {
    NoToken => "NoToken"
    InvalidToken => "InvalidToken"
    Expired => "Expired"
    Kicked => "Kicked"
    Superseded => "Superseded"
    RefreshInvalid => "RefreshInvalid"
  }
}

///|
/// 统一错误模型：core 与 guard 贯穿使用，web 层（v2 防腐层）负责映射成响应码。
pub(all) suberror TokenError {
  NotLogin(NotLoginReason)
  NotPermission(String)
  NotRole(String)
  Disabled(String, Int64)
  Store(String)
}

///|
pub fn TokenError::message(self : TokenError) -> String {
  match self {
    NotLogin(reason) => "not login: \{reason.label()}"
    NotPermission(p) => "no permission: \{p}"
    NotRole(r) => "no role: \{r}"
    Disabled(reason, until) => "disabled until \{until.to_string()}: \{reason}"
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
