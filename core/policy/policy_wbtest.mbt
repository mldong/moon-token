///|
/// D 系列（D1–D10）：全部打在**领域服务与聚合根**上——同步、零 IO、判据单点。
/// 这是 DDD 分层的直接收益：并发三态 / 续期节流 / 权限组合 / 精确原因裁决
/// 都能在不起存储、不等时间的情况下测完。
///（`_wbtest.mbt` 是白盒档：与本包同包，可直接用包内名字与包内 import 别名。）
fn reason_or_invalid(reason : @err.NotLoginReason?) -> Int {
  match reason {
    None => -1
    Some(r) => r.code()
  }
}

fn missing_or_empty(item : String?) -> String {
  match item {
    None => ""
    Some(v) => v
  }
}

///|
test "D1 decide_concurrent Coexist 每次新签且不动既有 token" {
  let fam = @domain.AccountFamily::empty("u1")
  fam.add_member(@port.Device::of("pc"), "t-old", 1000L) |> ignore
  let plan = decide_concurrent(@port.Coexist, fam, @port.Device::of("mobile"), 500L)
  match plan.action {
    IssueNew => assert_true(true)
    Reuse(token) => fail("Coexist 不该复用既有 token，实得 " + token)
  }
  assert_eq(plan.supersede_tokens.length(), 0)
}

///|
test "D2 decide_concurrent Shared 同设备复用同一 token，换设备仍新签" {
  let fam = @domain.AccountFamily::empty("u1")
  fam.add_member(@port.Device::of("pc"), "t-pc", 9000L) |> ignore
  match decide_concurrent(@port.Shared, fam, @port.Device::of("pc"), 500L).action {
    Reuse(token) => assert_eq(token, "t-pc")
    IssueNew => fail("Shared 下同设备应复用")
  }
  match decide_concurrent(@port.Shared, fam, @port.Device::of("pad"), 500L).action {
    IssueNew => assert_true(true)
    Reuse(t) => fail("不该把 pad 复用到 " + t)
  }
}

///|
test "D3 decide_concurrent Supersede 新签并顶掉全设备既有 token" {
  let fam = @domain.AccountFamily::empty("u1")
  fam.add_member(@port.Device::of("pc"), "t-1", 9000L) |> ignore
  fam.add_member(@port.Device::of("mobile"), "t-2", 9000L) |> ignore
  let plan = decide_concurrent(@port.Supersede, fam, @port.Device::of("pad"), 500L)
  match plan.action {
    IssueNew => assert_true(true)
    Reuse(t) => fail("Supersede 必须新签，实得复用 " + t)
  }
  assert_eq(plan.supersede_tokens.length(), 2)
  assert_true(plan.supersede_tokens.contains("t-1"))
  assert_true(plan.supersede_tokens.contains("t-2"))
}

///|
test "D4 decide_renewal SlideOnAccess 节流窗内不写后端" {
  let input = RenewalInput::make(
    @port.SlideOnAccess,
    100_000L,
    10_000L,
    60_000L,
    0L,
    30_000L,
    20_000L,
  )
  match decide_renewal(input) {
    Skip => assert_true(true)
    Renew(x) => fail("窗内不该续期，实得 " + x.to_string())
    IdleExpired => fail("模式不是 IdleMark")
  }
}

///|
test "D5 decide_renewal SlideOnAccess 出窗续到新到期点，且不往回拽" {
  let input = RenewalInput::make(@port.SlideOnAccess, 100_000L, 10_000L, 60_000L, 0L, 30_000L, 50_000L)
  match decide_renewal(input) {
    Renew(target) => assert_eq(target, 110_000L)
    Skip => fail("出窗应续期")
    IdleExpired => fail("模式不是 IdleMark")
  }
  // 记住我档（到期点已在更远的未来）不能被普通续期缩短
  let ahead = RenewalInput::make(@port.SlideOnAccess, 999_999_999L, 10_000L, 60_000L, 0L, 0L, 50_000L)
  match decide_renewal(ahead) {
    Skip => assert_true(true)
    Renew(t) => fail("不该缩短有效期，实得 " + t.to_string())
    IdleExpired => fail("模式不是 IdleMark")
  }
}

///|
test "D6 decide_renewal IdleMark 闲置过活跃时效判过期，窗内放行" {
  match decide_renewal(RenewalInput::make(@port.IdleMark, 0L, 10_000L, 60_000L, 5_000L, 0L, 16_000L)) {
    IdleExpired => assert_true(true)
    _ => fail("闲置超阈值应判 IdleExpired")
  }
  match decide_renewal(RenewalInput::make(@port.IdleMark, 0L, 10_000L, 60_000L, 5_000L, 0L, 13_000L)) {
    Skip => assert_true(true)
    _ => fail("IdleMark 窗内不该改动会话")
  }
}

///|
test "D7 decide_permission / decide_role 的 AND 与 OR 语义" {
  let granted = ["user:info", "user:list"]
  assert_true(decide_permission(granted, ["user:info"], @port.And) is None)
  assert_eq(missing_or_empty(decide_permission(granted, ["user:info", "user:write"], @port.And)), "user:write")
  assert_true(decide_permission(granted, ["user:write", "user:list"], @port.Or) is None)
  assert_eq(missing_or_empty(decide_permission(granted, ["a:b", "c:d"], @port.Or)), "a:b")
  // 空 required ⇒ 放行（两种模式同判），别造出"要求零项却不通过"的怪语义
  assert_true(decide_permission(granted, [], @port.And) is None)
  assert_true(decide_permission(granted, [], @port.Or) is None)
  assert_eq(missing_or_empty(decide_role(["admin"], ["user"], @port.Or)), "user")
}

///|
test "D8 classify_access 的精确原因单点" {
  // 墓碑态在保留窗内：报被踢/被顶的精确原因，而不是笼统未登录
  assert_eq(reason_or_invalid(classify_access(@port.Kicked, 5_000L, 4_000L)), @err.Kicked.code())
  assert_eq(reason_or_invalid(classify_access(@port.Superseded, 5_000L, 4_000L)), @err.Superseded.code())
  // 墓碑窗已过但键还在的兜底档：仍然先报原因（原因比"过期"更有信息量）
  assert_eq(reason_or_invalid(classify_access(@port.Kicked, 3_000L, 4_000L)), @err.Kicked.code())
  // 正常态但已过签发时效
  assert_eq(reason_or_invalid(classify_access(@port.Active, 3_000L, 4_000L)), @err.Expired.code())
  // 完全正常 ⇒ 放行；expire_at=0 是不过期档
  assert_true(classify_access(@port.Active, 9_000L, 4_000L) is None)
  assert_true(classify_access(@port.Active, 0L, 4_000L) is None)
}

///|
test "D9 AccountFamily 的清扫义务与版本号单调" {
  let fam = @domain.AccountFamily::empty("u1")
  fam.add_member(@port.Device::of("pc"), "t-alive", 9_000L) |> ignore
  fam.add_member(@port.Device::of("mobile"), "t-dead", 1_000L) |> ignore
  let version_before = fam.version()
  assert_eq(fam.prune_expired(5_000L), 1)
  assert_eq(fam.all_tokens().length(), 1)
  assert_true(fam.has_token("t-alive"))
  assert_true(!fam.has_token("t-dead"))
  assert_true(fam.version() > version_before)
  // 再清一次是空操作：不重复增版本
  let after = fam.version()
  assert_eq(fam.prune_expired(5_000L), 0)
  assert_eq(fam.version(), after)
}

///|
test "D10 加成员判重＝幂等空操作，线格式往返保形状" {
  let fam = @domain.AccountFamily::empty("u1")
  assert_true(fam.add_member(@port.Device::of("pc"), "t-1", 9_000L))
  let version_first = fam.version()
  assert_true(!fam.add_member(@port.Device::of("pc"), "t-1", 9_000L))
  assert_eq(fam.version(), version_first)
  assert_eq(fam.all_tokens().length(), 1)
  match @domain.AccountFamily::parse("u1", fam.payload()) {
    None => fail("族记录往返失败 payload=" + fam.payload())
    Some(copy) => {
      assert_eq(copy.version(), version_first)
      assert_true(copy.has_token("t-1"))
      assert_eq(copy.all_tokens().length(), 1)
    }
  }
  // 键位串了（login_id 不一致）必须拒收，不能默默拿到别人的族
  assert_true(@domain.AccountFamily::parse("someone-else", fam.payload()) is None)
}
