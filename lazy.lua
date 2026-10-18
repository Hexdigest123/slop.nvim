-- lazy.nvim package spec. `return { "hexdigest123/slop.nvim" }` in a user's config
-- picks this up, so `setup({})` is called automatically.
-- Do NOT add event/cmd/keys here: plugin/slop.lua lazy-loads every module itself.
return { "hexdigest123/slop.nvim", main = "slop", opts = {} }
