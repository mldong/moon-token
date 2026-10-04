name = "mldong/moon-token-store-file"

version = "0.1.9"

license = "Apache-2.0"

preferred_target = "wasm"

readme = "README.md"

repository = "https://github.com/mldong/moon-token"

description = "File-backed TokenStore for moon-token: in-memory authority with write-through to a directory, so a restart keeps login sessions without Redis or MySQL"

import {
  "mldong/moon-token-store@0.1.9",
  "moonbitlang/async@0.22.4",
}
keywords = [
  "token",
  "session",
  "file-store",
  "persistence",
  "write-through",
  "restart",
  "no-redis",
  "no-mysql",
  "tokenstore",
  "moonbit",
  "持久化",
  "会话",
]
