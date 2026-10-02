///|
/// 文件名派生的白盒用例：判"名字安全"与"两个键不会撞同一个名字"，同步档就够。

///|
fn name_is_safe(name : String) -> Bool {
  let mut ok = true
  for ch in name {
    if !(
      (ch >= 'a' && ch <= 'z') ||
        (ch >= 'A' && ch <= 'Z') ||
        (ch >= '0' && ch <= '9') ||
        ch == '.' || ch == '-' || ch == '_'
    ) {
      ok = false
    }
  }
  ok
}

///|
test "N1 再危险的键也只能产出安全文件名" {
  let hostile = [
    "user:T:a",
    "user:T:a b",
    "user:T:..",
    "user:T:a*b?c<d>e|f",
    "user:T:a\\b",
    "user:T:100%25",
    "user:A:中文登录号",
    "user:P:u:|?*<>\"\\%",
    "",
    "::::",
    "///",
  ]
  for key in hostile {
    assert_true(
      name_is_safe(file_name(key)),
      msg="文件名不安全：" + file_name(key),
    )
  }
}

///|
test "N2 同一键的名字稳定，不同键的名字不同" {
  assert_eq(file_name("user:T:abc"), file_name("user:T:abc"))
  // 前缀相同、尾部不同的两个键必须分开（可读前缀只是装饰，撞不得）
  assert_true(file_name("user:T:abc") != file_name("user:T:abd"))
  assert_true(file_name("user:T:abc") != file_name("user:A:abc"))
}

///|
test "N3 300 个真实形状的键零碰撞" {
  let seen : Array[String] = []
  for i in 0..<300 {
    let key = "user:T:tok" + i.to_string()
    let name = file_name(key)
    assert_true(!seen.contains(name), msg="重名：" + key + " → " + name)
    seen.push(name)
  }
  assert_eq(seen.length(), 300)
}

///|
test "N4 可读前缀取自键里的安全字符，全不安全时退化成 k" {
  assert_true(file_name("user:T:abc").has_prefix("userTabc"))
  assert_true(file_name("***").has_prefix("k."))
}
