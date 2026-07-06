profile = "library"
change-id = 154587

[build]
profiler = true

[llvm]
download-ci-llvm = true

[rust]
lto = "fat"
codegen-units = 1
channel = "stable"
opt-level = "z"
