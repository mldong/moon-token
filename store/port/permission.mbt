///|
/// 授权快照（`P:` 键的 payload）：权限集 + 角色集 + 超管位，**一次算好、会话内反复读**。
///
/// 为什么不每次请求现问业务：这三样都是业务库里的数据（用户→角色→权限），一次鉴权打三次库
/// 是明显的错。通行做法是把它们收成一份快照跟着会话走；这里做的是同一件事，
/// 只把"业务用户对象"收窄成"裁决要用的三样数"。
///
/// 为什么不带 `extra`/用户资料：那是业务的形状，库不认识（`T:` 的 `extra` 已经够了）。
/// 快照里只放**判定要用**的东西，多一个字段就多一份会过期的真相。
///
/// 为什么它**不是权威**：命中与否只决定"要不要问业务"，绝不决定"放不放行"。
/// 解不出来就当 miss 回填；键跟着 token 走，会话一死快照一起没，不会留下一个还能判东西的孤儿。
pub(all) struct PermissionRecord {
  /// 归属校验用：这份快照是给谁的。判定不看它，看 `T:` 里的登录号。
  mut login_id : String
  mut perms : Array[String]
  mut roles : Array[String]
  /// 超级管理员：权限中间件据此跳过权限/角色校验（仍要求已登录）。
  /// 值由业务判（`PermissionProvider::is_super_admin`），库里没有用户模型。
  mut super_admin : Bool
  /// 这份快照是哪一刻拼出来的（ms）。不进判定，只给排障看"缓存了多久"。
  mut built_at : Int64
}

///|
pub fn PermissionRecord::make(
  login_id : String,
  perms : Array[String],
  roles : Array[String],
  super_admin : Bool,
  built_at : Int64,
) -> PermissionRecord {
  let r : PermissionRecord = {
    login_id,
    perms,
    roles,
    super_admin,
    built_at,
  }
  r
}

///|
pub fn PermissionRecord::encode(self : PermissionRecord) -> String {
  encode_record([
    ("login", self.login_id),
    ("perms", encode_list(self.perms)),
    ("roles", encode_list(self.roles)),
    ("sa", if self.super_admin { "1" } else { "0" }),
    ("at", self.built_at.to_string()),
  ])
}

///|
/// 形状不合 ⇒ `None`，调用方按"没有缓存"去回填——快照坏了的最坏结果是多问业务一次。
pub fn PermissionRecord::decode(text : String) -> PermissionRecord? {
  match decode_record(text) {
    None => None
    Some(f) => {
      let login_id = record_field_or(f, "login", "")
      if login_id.is_empty() {
        None
      } else {
        let r : PermissionRecord = {
          login_id,
          perms: decode_list(record_field_or(f, "perms", "")),
          roles: decode_list(record_field_or(f, "roles", "")),
          super_admin: record_field_or(f, "sa", "0") == "1",
          built_at: record_field_int64(f, "at"),
        }
        Some(r)
      }
    }
  }
}
