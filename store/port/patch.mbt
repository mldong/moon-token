///|
/// 意图补丁：聚合一致性边界内的变更意图（不是 setter 序列）。
/// **`apply` 是反向索引（`A:` 族与 `T:` 状态）的唯一写入口**，裸 `set/del` 只服务附加数据。
/// 契约三条：① 同一批内按序生效；② 整体幂等（重复投递结果一致——故版本号只随成员增删变化）；
/// ③ 不带时钟——需要绝对时刻的地方一律传算好的 `deadline`/`expire_at`，保证多后端同判据同答案。
pub(all) enum FamilyPatch {
  /// 反向索引加成员：login_id, device, token, 该 token 的到期时刻
  AddToken(String, Device, String, Int64)
  /// 置状态墓碑并改写到期时刻（"被踢方拿精确原因"靠它）：tokens, status, deadline
  MarkStatus(Array[String], SessionStatus, Int64)
  /// 摘除成员并删对应 `T:` 键：login_id, tokens
  RemoveTokens(String, Array[String])
  /// 续期：tokens, 新的到期时刻
  TouchExpire(Array[String], Int64)
  /// 附加数据直写（`S:`/`D:`/`R:`）：key, payload, expire_at（<=0 表示不过期）
  PutRecord(String, String, Int64)
  /// 删任意键
  RemoveKeys(Array[String])
}

///|
/// 键位约定（realm 由 TokenAuth 持有并拼进前缀）
pub(all) struct KeySpace {
  realm : String
}

///|
pub fn KeySpace::of(realm : String) -> KeySpace {
  let k : KeySpace = { realm, }
  k
}

///|
pub fn KeySpace::token(self : KeySpace, token : String) -> String {
  "\{self.realm}:T:\{token}"
}

///|
pub fn KeySpace::family(self : KeySpace, login_id : String) -> String {
  "\{self.realm}:A:\{login_id}"
}

///|
pub fn KeySpace::account_session(self : KeySpace, login_id : String) -> String {
  "\{self.realm}:S:\{login_id}"
}

///|
pub fn KeySpace::refresh(self : KeySpace, refresh_token : String) -> String {
  "\{self.realm}:R:\{refresh_token}"
}

///|
pub fn KeySpace::ban(self : KeySpace, login_id : String) -> String {
  "\{self.realm}:D:\{login_id}"
}
