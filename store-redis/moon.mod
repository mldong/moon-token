name = "mldong/moon-token-store-redis"

version = "0.1.17"

license = "Apache-2.0"

preferred_target = "wasm"

readme = "README.md"

repository = "https://github.com/mldong/moon-token"

description = "Redis-backed TokenStore for moon-token: shared sessions across processes and instances, with family CAS, Lua get-and-delete and a session index that pages exactly like the in-memory adapter"

keywords = [
  "token",
  "token-store",
  "session-store",
  "redis",
  "valkey",
  "session-management",
  "shared-session",
  "storage-port",
  "moonbit",
  "令牌",
  "会话",
  "存储端口",
  "共享会话",
]

import {
  "mldong/moon-token-store@0.1.17",
  "oboard/redis@0.2.3",
  "moonbitlang/async@0.22.4",
}
