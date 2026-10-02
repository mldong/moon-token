///|
/// G series: route permission policy (white-box, pure sync).
///
/// Fixture data is generated from the real controllers of the mldong Java baseline:
/// 199 endpoints carrying an auth declaration, split into 9 exempt / 17 multi-code OR /
/// 2 renamed-code, and 171 that must be satisfied by path derivation alone.
///
/// The assertion is per-endpoint equivalence of the FINAL decision, not a derivation
/// hit-rate: a renamed code is a legitimate case, not a bug to be fixed away.

fn mk_exempt() -> Array[String] {
  [
    "/app/appVersion/check",
    "/dev/schema/getByTableName",
    "/sys/getSm2PublicKey",
    "/sys/config/public",
    "/{module}/{tableName}/export",
    "/sys/sms/sendCode",
    "/sys/sms/verifyCode",
    "/thirdParty/checkStarred",
    "/thirdPartyCallback/{channelType}/{serviceType}",
  ]
}

fn mk_or_fixture() -> Array[(String, Array[String])] {
  [
    ("/dev/schema/detail", ["dev:schema:detail", "dev:schema:updateListKeys", "dev:schema:updateSearchFormKeys"]),
    ("/dev/schema/dbTable", ["dev:schema:dbTable", "dev:schema:importTable"]),
    ("/sys/dept/tree", ["sys:dept:tree", "sys:role:grantDataScope"]),
    ("/sys/dict/generateExportUrl", ["sys:dict:generateExportUrl", "sys:dict:export"]),
    ("/sys/opLog/detail", ["sys:opLog:detail", "sys:opLog:page", "sys:opLog:update"]),
    ("/sys/rbac/roleMenuIds", ["sys:rbac:roleMenuIds", "sys:rbac:saveRoleMenu"]),
    ("/sys/smsLog/detail", ["sys:smsLog:detail", "sys:smsLog:page"]),
    ("/sys/smsTemplate/detail", ["sys:smsTemplate:detail", "sys:smsTemplate:page"]),
    ("/sys/taskExecutionHistory/detail", ["sys:taskExecutionHistory:detail", "sys:taskExecutionHistory:page", "sys:taskExecutionHistory:update"]),
    ("/sys/taskExecutionQueue/detail", ["sys:taskExecutionQueue:detail", "sys:taskExecutionQueue:page", "sys:taskExecutionQueue:update"]),
    ("/sys/user/locked", ["sys:user:locked", "sys:user:unLocked"]),
    ("/sys/user/unLocked", ["sys:user:locked", "sys:user:unLocked"]),
    ("/sys/visLog/detail", ["sys:visLog:detail", "sys:visLog:page", "sys:visLog:update"]),
    ("/wf/processDefine/detail", ["wf:processDefine:detail", "wf:processDesign:listByType"]),
    ("/wf/processDefine/startAndExecute", ["wf:processDefine:startAndExecute", "wf:processDesign:listByType"]),
    ("/wf/processDefine/getLastByName", ["wf:processDefine:detail", "wf:processDesign:listByType", "wf:processDefine:getLastByName"]),
    ("/wf/processTask/candidatePage", ["wf:processTask:execute", "wf:processTask:candidatePage"]),
  ]
}

fn mk_rename_fixture() -> Array[(String, String)] {
  [
    ("/sys/timer/start", "sys:timer:stop"),
    ("/wf/processTask/jumpAbleTaskNameList", "wf:processTask:execute"),
  ]
}

fn mk_derived_fixture() -> Array[(String, String)] {
  [
    ("/biz/demo/save", "biz:demo:save"),
    ("/biz/demo/remove", "biz:demo:remove"),
    ("/biz/demo/update", "biz:demo:update"),
    ("/biz/demo/detail", "biz:demo:detail"),
    ("/biz/demo/page", "biz:demo:page"),
    ("/dev/schema/save", "dev:schema:save"),
    ("/dev/schema/remove", "dev:schema:remove"),
    ("/dev/schema/update", "dev:schema:update"),
    ("/dev/schema/updateListKeys", "dev:schema:updateListKeys"),
    ("/dev/schema/updateSearchFormKeys", "dev:schema:updateSearchFormKeys"),
    ("/dev/schema/page", "dev:schema:page"),
    ("/dev/schema/importTable", "dev:schema:importTable"),
    ("/dev/schema/updateDesigner", "dev:schema:updateDesigner"),
    ("/dev/schemaField/save", "dev:schemaField:save"),
    ("/dev/schemaField/remove", "dev:schemaField:remove"),
    ("/dev/schemaField/update", "dev:schemaField:update"),
    ("/dev/schemaField/detail", "dev:schemaField:detail"),
    ("/dev/schemaField/page", "dev:schemaField:page"),
    ("/dev/schemaField/updateSort", "dev:schemaField:updateSort"),
    ("/dev/schemaGroup/save", "dev:schemaGroup:save"),
    ("/dev/schemaGroup/remove", "dev:schemaGroup:remove"),
    ("/dev/schemaGroup/update", "dev:schemaGroup:update"),
    ("/dev/schemaGroup/detail", "dev:schemaGroup:detail"),
    ("/dev/schemaGroup/page", "dev:schemaGroup:page"),
    ("/sys/playUser", "sys:playUser"),
    ("/sys/config/save", "sys:config:save"),
    ("/sys/config/remove", "sys:config:remove"),
    ("/sys/config/update", "sys:config:update"),
    ("/sys/config/detail", "sys:config:detail"),
    ("/sys/config/page", "sys:config:page"),
    ("/sys/dept/save", "sys:dept:save"),
    ("/sys/dept/remove", "sys:dept:remove"),
    ("/sys/dept/update", "sys:dept:update"),
    ("/sys/dept/detail", "sys:dept:detail"),
    ("/sys/dept/page", "sys:dept:page"),
    ("/sys/dept/list", "sys:dept:list"),
    ("/sys/dept/autoSort", "sys:dept:autoSort"),
    ("/sys/dept/updateSort", "sys:dept:updateSort"),
    ("/sys/dict/save", "sys:dict:save"),
    ("/sys/dict/remove", "sys:dict:remove"),
    ("/sys/dict/update", "sys:dict:update"),
    ("/sys/dict/detail", "sys:dict:detail"),
    ("/sys/dict/page", "sys:dict:page"),
    ("/sys/dict/clearCache", "sys:dict:clearCache"),
    ("/sys/dict/importTo", "sys:dict:importTo"),
    ("/sys/dictItem/save", "sys:dictItem:save"),
    ("/sys/dictItem/remove", "sys:dictItem:remove"),
    ("/sys/dictItem/update", "sys:dictItem:update"),
    ("/sys/dictItem/detail", "sys:dictItem:detail"),
    ("/sys/dictItem/page", "sys:dictItem:page"),
    ("/sys/fileInfo/save", "sys:fileInfo:save"),
    ("/sys/fileInfo/remove", "sys:fileInfo:remove"),
    ("/sys/fileInfo/update", "sys:fileInfo:update"),
    ("/sys/fileInfo/detail", "sys:fileInfo:detail"),
    ("/sys/fileInfo/page", "sys:fileInfo:page"),
    ("/sys/machine/info", "sys:machine:info"),
    ("/sys/menu/save", "sys:menu:save"),
    ("/sys/menu/remove", "sys:menu:remove"),
    ("/sys/menu/update", "sys:menu:update"),
    ("/sys/menu/detail", "sys:menu:detail"),
    ("/sys/menu/page", "sys:menu:page"),
    ("/sys/menu/list", "sys:menu:list"),
    ("/sys/menu/syncRoute", "sys:menu:syncRoute"),
    ("/sys/menu/tree", "sys:menu:tree"),
    ("/sys/message/save", "sys:message:save"),
    ("/sys/message/update", "sys:message:update"),
    ("/sys/opLog/save", "sys:opLog:save"),
    ("/sys/opLog/remove", "sys:opLog:remove"),
    ("/sys/opLog/update", "sys:opLog:update"),
    ("/sys/opLog/page", "sys:opLog:page"),
    ("/sys/post/save", "sys:post:save"),
    ("/sys/post/remove", "sys:post:remove"),
    ("/sys/post/update", "sys:post:update"),
    ("/sys/post/detail", "sys:post:detail"),
    ("/sys/post/page", "sys:post:page"),
    ("/sys/rbac/saveRoleMenu", "sys:rbac:saveRoleMenu"),
    ("/sys/rbac/roleMenuList", "sys:rbac:roleMenuList"),
    ("/sys/rbac/saveUserRole", "sys:rbac:saveUserRole"),
    ("/sys/rbac/removeUserRole", "sys:rbac:removeUserRole"),
    ("/sys/rbac/userListByRoleId", "sys:rbac:userListByRoleId"),
    ("/sys/rbac/userListExcludeRoleId", "sys:rbac:userListExcludeRoleId"),
    ("/sys/relThirdAccount/save", "sys:relThirdAccount:save"),
    ("/sys/relThirdAccount/remove", "sys:relThirdAccount:remove"),
    ("/sys/relThirdAccount/update", "sys:relThirdAccount:update"),
    ("/sys/relThirdAccount/detail", "sys:relThirdAccount:detail"),
    ("/sys/relThirdAccount/page", "sys:relThirdAccount:page"),
    ("/sys/role/save", "sys:role:save"),
    ("/sys/role/remove", "sys:role:remove"),
    ("/sys/role/update", "sys:role:update"),
    ("/sys/role/detail", "sys:role:detail"),
    ("/sys/role/page", "sys:role:page"),
    ("/sys/role/grantDataScope", "sys:role:grantDataScope"),
    ("/sys/sms/sendNotification", "sys:sms:sendNotification"),
    ("/sys/sms/batchSendNotification", "sys:sms:batchSendNotification"),
    ("/sys/smsLog/save", "sys:smsLog:save"),
    ("/sys/smsLog/remove", "sys:smsLog:remove"),
    ("/sys/smsLog/update", "sys:smsLog:update"),
    ("/sys/smsLog/page", "sys:smsLog:page"),
    ("/sys/smsTemplate/save", "sys:smsTemplate:save"),
    ("/sys/smsTemplate/remove", "sys:smsTemplate:remove"),
    ("/sys/smsTemplate/update", "sys:smsTemplate:update"),
    ("/sys/smsTemplate/page", "sys:smsTemplate:page"),
    ("/sys/taskExecutionHistory/save", "sys:taskExecutionHistory:save"),
    ("/sys/taskExecutionHistory/remove", "sys:taskExecutionHistory:remove"),
    ("/sys/taskExecutionHistory/update", "sys:taskExecutionHistory:update"),
    ("/sys/taskExecutionHistory/page", "sys:taskExecutionHistory:page"),
    ("/sys/taskExecutionHistory/restore", "sys:taskExecutionHistory:restore"),
    ("/sys/taskExecutionQueue/save", "sys:taskExecutionQueue:save"),
    ("/sys/taskExecutionQueue/remove", "sys:taskExecutionQueue:remove"),
    ("/sys/taskExecutionQueue/update", "sys:taskExecutionQueue:update"),
    ("/sys/taskExecutionQueue/page", "sys:taskExecutionQueue:page"),
    ("/sys/taskExecutionQueue/cancelTask", "sys:taskExecutionQueue:cancelTask"),
    ("/sys/timer/stop", "sys:timer:stop"),
    ("/sys/timer/update", "sys:timer:update"),
    ("/sys/timer/detail", "sys:timer:detail"),
    ("/sys/timer/page", "sys:timer:page"),
    ("/sys/timer/reset", "sys:timer:reset"),
    ("/sys/timer/executeImmediate", "sys:timer:executeImmediate"),
    ("/sys/user/save", "sys:user:save"),
    ("/sys/user/remove", "sys:user:remove"),
    ("/sys/user/update", "sys:user:update"),
    ("/sys/user/detail", "sys:user:detail"),
    ("/sys/user/page", "sys:user:page"),
    ("/sys/user/resetPassword", "sys:user:resetPassword"),
    ("/sys/user/grantRole", "sys:user:grantRole"),
    ("/sys/user/onlineUserList", "sys:user:onlineUserList"),
    ("/sys/user/logoutByTokenValue", "sys:user:logoutByTokenValue"),
    ("/sys/user/kickoutByTokenValue", "sys:user:kickoutByTokenValue"),
    ("/sys/user/logoutByLoginId", "sys:user:logoutByLoginId"),
    ("/sys/user/kickoutByLoginId", "sys:user:kickoutByLoginId"),
    ("/sys/visLog/save", "sys:visLog:save"),
    ("/sys/visLog/remove", "sys:visLog:remove"),
    ("/sys/visLog/update", "sys:visLog:update"),
    ("/sys/visLog/page", "sys:visLog:page"),
    ("/wf/processDefine/remove", "wf:processDefine:remove"),
    ("/wf/processDefine/page", "wf:processDefine:page"),
    ("/wf/processDefine/upAndDown", "wf:processDefine:upAndDown"),
    ("/wf/processDesign/save", "wf:processDesign:save"),
    ("/wf/processDesign/remove", "wf:processDesign:remove"),
    ("/wf/processDesign/update", "wf:processDesign:update"),
    ("/wf/processDesign/detail", "wf:processDesign:detail"),
    ("/wf/processDesign/page", "wf:processDesign:page"),
    ("/wf/processDesign/updateDefine", "wf:processDesign:updateDefine"),
    ("/wf/processDesign/deploy", "wf:processDesign:deploy"),
    ("/wf/processDesign/redeploy", "wf:processDesign:redeploy"),
    ("/wf/processDesign/listByType", "wf:processDesign:listByType"),
    ("/wf/processDesignHis/save", "wf:processDesignHis:save"),
    ("/wf/processDesignHis/remove", "wf:processDesignHis:remove"),
    ("/wf/processDesignHis/update", "wf:processDesignHis:update"),
    ("/wf/processDesignHis/detail", "wf:processDesignHis:detail"),
    ("/wf/processDesignHis/page", "wf:processDesignHis:page"),
    ("/wf/processInstance/startAndExecute", "wf:processInstance:startAndExecute"),
    ("/wf/processInstance/page", "wf:processInstance:page"),
    ("/wf/processInstance/withdraw", "wf:processInstance:withdraw"),
    ("/wf/processInstance/createCCInstance", "wf:processInstance:createCCInstance"),
    ("/wf/processInstance/updateCCStatus", "wf:processInstance:updateCCStatus"),
    ("/wf/processInstance/ccList", "wf:processInstance:ccList"),
    ("/wf/processSurrogate/save", "wf:processSurrogate:save"),
    ("/wf/processSurrogate/remove", "wf:processSurrogate:remove"),
    ("/wf/processSurrogate/update", "wf:processSurrogate:update"),
    ("/wf/processSurrogate/detail", "wf:processSurrogate:detail"),
    ("/wf/processSurrogate/page", "wf:processSurrogate:page"),
    ("/wf/processTaskActor/save", "wf:processTaskActor:save"),
    ("/wf/processTaskActor/remove", "wf:processTaskActor:remove"),
    ("/wf/processTaskActor/update", "wf:processTaskActor:update"),
    ("/wf/processTaskActor/detail", "wf:processTaskActor:detail"),
    ("/wf/processTaskActor/page", "wf:processTaskActor:page"),
    ("/wf/processTask/todoList", "wf:processTask:todoList"),
    ("/wf/processTask/doneList", "wf:processTask:doneList"),
    ("/wf/processTask/execute", "wf:processTask:execute"),
    ("/wf/processTask/surrogate", "wf:processTask:surrogate"),
  ]
}

test "G1 derive_perm: segments joined by colon, variable/empty paths not derived" {
  assert_eq(derive_perm("/sys/user/save"), Some("sys:user:save"))
  assert_eq(derive_perm("/wf/processTask/page"), Some("wf:processTask:page"))
  assert_eq(derive_perm("//sys//user//page"), Some("sys:user:page"))
  assert_eq(derive_perm("/"), None)
  assert_eq(derive_perm("/{module}/{tableName}/export"), None)
}

test "G2 order: exempt > overrides > derivation > login-only" {
  let p = RoutePolicy::new()
    .exempt("/sys/login")
    .rule(RouteRule::make("/sys/opLog/detail", ["a", "b"]).with_perm_mode(@port.Or))
  assert_true(p.resolve("/sys/login") is Public)
  match p.resolve("/sys/opLog/detail") {
    Guarded(r) => {
      assert_eq(r.perms.length(), 2)
      assert_true(r.perm_mode is @port.Or)
    }
    _ => fail("override did not win")
  }
  match p.resolve("/sys/user/page") {
    Guarded(r) => assert_eq(r.perms[0], "sys:user:page")
    _ => fail("derivation did not apply")
  }
  let off = RoutePolicy::new()
  off.by_convention = false
  assert_true(off.resolve("/sys/user/page") is LoginOnly)
  assert_true(p.resolve("/{module}/x/export") is LoginOnly)
}

test "G3 specificity: most literal segments wins, declaration order does not decide" {
  let p = RoutePolicy::new()
    .rule(RouteRule::make("/sys/**", ["broad"]))
    .rule(RouteRule::make("/sys/user/page", ["precise"]))
  match p.resolve("/sys/user/page") {
    Guarded(r) => assert_eq(r.perms[0], "precise")
    _ => fail("most specific rule did not win")
  }
  let q = RoutePolicy::new()
    .rule(RouteRule::make("/sys/user/*", ["first"]))
    .rule(RouteRule::make("/sys/user/*", ["second"]))
  match q.resolve("/sys/user/page") {
    Guarded(r) => assert_eq(r.perms[0], "first")
    _ => fail("same specificity should keep the first declared")
  }
}

test "G4 load-time audit helpers" {
  let p = RoutePolicy::new()
    .rule(RouteRule::make("/a/b", ["x", "y"]).with_perm_mode(@port.Or))
    .rule(RouteRule::make("/a/c", ["x", "y"]))
  assert_eq(p.unflagged_or(["/a/b"]), ["/a/c"])
  let q = RoutePolicy::new().rule(RouteRule::make("/sys/timer/start", ["sys:timer:stop"]))
  let e = q.exceptions(["/sys/user/page", "/sys/timer/start", "/error"])
  assert_true(e.contains("/sys/timer/start"))
  assert_true(!e.contains("/sys/user/page"))
}

test "G5 fixture: every real endpoint ends up with the declared decision" {
  let p = RoutePolicy::new()
  for path in mk_exempt() {
    p.exempt(path) |> ignore
  }
  for pair in mk_or_fixture() {
    p.rule(RouteRule::make(pair.0, pair.1).with_perm_mode(@port.Or)) |> ignore
  }
  for pair in mk_rename_fixture() {
    p.rule(RouteRule::make(pair.0, [pair.1])) |> ignore
  }
  for path in mk_exempt() {
    assert_true(p.resolve(path) is Public)
  }
  for pair in mk_or_fixture() {
    match p.resolve(pair.0) {
      Guarded(r) => {
        assert_eq(r.perms, pair.1)
        assert_true(r.perm_mode is @port.Or)
      }
      _ => fail("multi-code endpoint missed the override: " + pair.0)
    }
  }
  for pair in mk_rename_fixture() {
    match p.resolve(pair.0) {
      Guarded(r) => assert_eq(r.perms, [pair.1])
      _ => fail("renamed endpoint missed the override: " + pair.0)
    }
  }
  for pair in mk_derived_fixture() {
    match p.resolve(pair.0) {
      Guarded(r) => assert_eq(r.perms, [pair.1])
      _ => fail("derivation did not cover: " + pair.0)
    }
  }
}
