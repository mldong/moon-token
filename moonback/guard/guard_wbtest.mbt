///|
/// MB10：取 token 的来源优先级（白盒，因为 `header_or_cookie` 是本包私有的）。
///
/// 这一条为什么单列：cookie 只是**载体**，把"cookie 模式"做成一条不过 `TokenStore` 的通路，
/// 等于交付一个"改掉字符串就能冒充任何人"的对照组（实测记在 hub 的 moonback 复测报告 §11）。
/// 所以这里钉的是"头优先、空串按没有处理、两处都没有给 None"，而不是"cookie 能登录"。

///|
test "MB10 头优先、空头落 cookie、两处都空给 None" {
  let pairs : Array[(String, String)] = [("Authorization", "tok-head")]
  let with_header = @mb.Headers::from(pairs)
  let cookies : Map[String, String] = Map([("Authorization", "tok-cookie")])
  assert_eq(
    header_or_cookie(with_header, cookies, "Authorization"),
    Some("tok-head"),
  )

  let empty_pairs : Array[(String, String)] = [("Authorization", "")]
  let empty_header = @mb.Headers::from(empty_pairs)
  assert_eq(
    header_or_cookie(empty_header, cookies, "Authorization"),
    Some("tok-cookie"),
    msg="空的 Authorization 头要按『没带』处理，否则会盖掉 cookie",
  )

  let none_pairs : Array[(String, String)] = []
  let bare = @mb.Headers::from(none_pairs)
  assert_eq(header_or_cookie(bare, cookies, "sid"), None)
  assert_eq(header_or_cookie(bare, Map([]), "sid"), None)
}
