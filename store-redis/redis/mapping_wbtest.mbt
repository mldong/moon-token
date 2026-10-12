///|
/// RM 系列：不连服务端的"尺子"测试。
///
/// 这一层存在的理由很具体：Redis 适配器最容易做错的地方不是网络，而是**与参考实现不同序**
/// 和**按字节切非 ASCII 键**——前者会让翻页重漏，后者正是上一代驱动翻车的那类字节/字符混淆。
/// 尺子先在内存档上对齐，真机档（RS 系列）才谈得上"两后端同答案"。

///|
fn mk_listing(token : String, login_time : Int64) -> @port.SessionListing {
  @port.SessionListing::make(token, "u1", "pc", login_time, login_time + 1000L)
}

///|
test "RM1 剥键头按字符数走，非 ASCII 的 realm 不错位" {
  let keys = @port.KeySpace::of("用户域")
  let key = keys.token("tok-1")
  // realm 与分隔符合起来是多字节，按字节切片会切错；这里必须原样拿回 token
  assert_eq(strip_head(key, "用户域:T:"), "tok-1")
  assert_eq(keys.family("用户域"), "用户域:A:用户域")
}

///|
test "RM2 同刻两枚按 token 字典序倒排，与内存版同一把尺子" {
  let upper = mk_listing("ZZZ", 1000L)
  let lower = mk_listing("aaa", 1000L)
  // 降序里 "aaa" 在前、"ZZZ" 在后：同刻没有第二个维度可依赖，只能用 token 兜底
  assert_true(listing_newer(lower, upper))
  assert_false(listing_newer(upper, lower))
  assert_true(listing_newer(mk_listing("any", 2000L), mk_listing("zzz", 1000L)))
}

///|
test "RM3 游标只放行排在它之后的条目" {
  let cursor = @port.make_cursor(mk_listing("aaa", 1000L))
  match @port.parse_cursor(cursor) {
    None => fail("游标解不开，翻页必然重漏")
    Some(pair) => {
      // 同刻但 token 更小 ⇒ 在游标之后，放行
      assert_true(sits_after(mk_listing("ZZZ", 1000L), pair))
      // 同刻且 token 更大 ⇒ 排在游标前面（已经给过），挡掉
      assert_false(sits_after(mk_listing("bbb", 1000L), pair))
      // 更旧的时刻 ⇒ 放行
      assert_true(sits_after(mk_listing("zzz", 999L), pair))
      // 游标本身 ⇒ 挡掉（比较的是位置不是存在性）
      assert_false(sits_after(mk_listing("aaa", 1000L), pair))
    }
  }
}

///|
test "RM4 排序函数把乱序摆回预期序" {
  let fresh = mk_listing("fresh", 3000L)
  let tie_a = mk_listing("tie-a", 2000L)
  let tie_b = mk_listing("tie-b", 2000L)
  let old = mk_listing("old", 1000L)
  let shuffled = [tie_b, old, fresh, tie_a]
  let tokens = sort_listings(shuffled).map((item : @port.SessionListing) => {
    item.token
  })
  // 新在前；同刻的两个按 token 字典序倒排 ⇒ tie-b 在 tie-a 之前
  assert_eq(tokens.join(","), "fresh,tie-b,tie-a,old")
}
