///|
fn storage_keys(keys : KeySpace, suffix : String) -> Array[String] {
  [
    keys.token(suffix),
    keys.family(suffix),
    keys.account_session(suffix),
    keys.refresh(suffix),
    keys.ban(suffix),
    keys.grants(suffix),
    keys.session_index(),
  ]
}

///|
test "KS1 ordinary realm keeps all seven key formats" {
  let keys = KeySpace::of("user-1.example")
  assert_eq(keys.realm, "user-1.example")
  assert_eq(
    storage_keys(keys, "id").join(","),
    "user-1.example:T:id,user-1.example:A:id,user-1.example:S:id,user-1.example:R:id,user-1.example:D:id,user-1.example:P:id,user-1.example:Z",
  )
}

///|
test "KS2 special realm characters are encoded without changing the input" {
  let realm = "%:*?[]\\中文"
  let keys = KeySpace::of(realm)
  assert_eq(keys.realm, realm)
  assert_eq(keys.prefix(), "%25%3A%2A%3F%5B%5D%5C中文:")
  assert_eq(keys.token("t:*"), "%25%3A%2A%3F%5B%5D%5C中文:T:t:*")
  assert_eq(keys.family("id"), "%25%3A%2A%3F%5B%5D%5C中文:A:id")
}

///|
test "KS3 literal percent escapes cannot alias encoded realms" {
  let inputs = [":", "%3A", "%253A", "*", "%2A", "%"]
  let expected = [
    "%3A:T:t", "%253A:T:t", "%25253A:T:t", "%2A:T:t", "%252A:T:t", "%25:T:t",
  ]
  for i in 0..<inputs.length() {
    assert_eq(KeySpace::of(inputs[i]).token("t"), expected[i])
  }
}

///|
test "KS4 Chinese and empty realms retain their ordinary key formats" {
  for realm in ["中文领域", ""] {
    let actual = storage_keys(KeySpace::of(realm), "值")
    let suffixes = ["T:值", "A:值", "S:值", "R:值", "D:值", "P:值", "Z"]
    for i in 0..<actual.length() {
      assert_eq(actual[i], realm + ":" + suffixes[i])
    }
  }
}

///|
test "KS5 nested realms isolate all seven key families" {
  let parent = KeySpace::of("a")
  let parent_heads = storage_keys(parent, "")
  for segment in ["T:x", "A:x", "S:x", "R:x", "D:x", "P:x", "Z:x"] {
    let child = KeySpace::of("a:" + segment)
    let keys = storage_keys(child, "id")
    for key in keys {
      for head in parent_heads {
        assert_false(key.has_prefix(head))
      }
    }
  }
}
