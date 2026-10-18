-- :checkhealth slop entry point (discovered by name). Implementation: lua/slop/core/health.lua.
-- Modules must NOT add their own lua/slop/**/health.lua; they implement spec.health() instead.
return {
  check = function()
    require("slop.core.health").check()
  end,
}
