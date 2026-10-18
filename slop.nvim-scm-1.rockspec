rockspec_format = "3.0"
package = "slop.nvim"
version = "scm-1"
source = { url = "git+https://github.com/hexdigest123/slop.nvim" }
description = {
  summary = "A modular do-everything Neovim plugin: AI completion, commit messages, agent edits, REST, cloak, terminal",
  homepage = "https://github.com/hexdigest123/slop.nvim",
  license = "MIT",
  labels = { "neovim", "ai", "completion", "rest", "terminal" },
}
dependencies = { "lua >= 5.1" }
test_dependencies = { "nlua" }
build = { type = "builtin", copy_directories = { "doc", "plugin" } }
