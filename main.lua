-- HiddenStats: adds a Summary page showing each stat's IV (derived from its
-- DV) and EV (derived from Stat Exp).
--
-- Three ways this mod can end up rendering, chosen automatically at load:
--
--  1. Standalone (no Kanto Reforged, no Gen1 Modern UI): wraps the native
--     src.ui.SummaryMenu class directly, appending one page after whatever
--     native pages already exist.
--  2. Standalone + Gen1 Modern UI: same native wrap, plus a small adapter
--     registered with gen1_modern_ui that supplies just the extra page --
--     gen1_modern_ui already fully models the native pages on its own, so
--     this mod only needs to contribute the one page it adds.
--  3. With Kanto Reforged: Kanto Reforged owns the SummaryMenu screen itself
--     (native and modern UI both), so this mod does not touch either one.
--     It only publishes `mod.exports.summaryPageModel` / `drawSummaryPage`
--     for Kanto Reforged's own adapter to call into. This requires a small
--     compatibility hook on Kanto Reforged's side (tracked separately --
--     see the project README's Phase 2 section).

local function dvToIv(dv) return math.floor((dv * 31) / 15) end
local function statExpToEv(exp) return math.floor(math.sqrt(exp)) end

-- Gen1 has no separate HP DV; it's the low bit of each of the other four DVs.
local function hpDv(dvs)
  return ((dvs.attack or 0) % 2) * 8
    + ((dvs.defense or 0) % 2) * 4
    + ((dvs.speed or 0) % 2) * 2
    + (dvs.special or 0) % 2
end

local function buildStats(mon)
  local dvs = mon.dvs or {}
  local statExp = mon.statExp or {}
  return {
    { label = "HP", dv = hpDv(dvs), exp = statExp.hp or 0 },
    { label = "ATTACK", dv = dvs.attack or 0, exp = statExp.attack or 0 },
    { label = "DEFENSE", dv = dvs.defense or 0, exp = statExp.defense or 0 },
    { label = "SPEED", dv = dvs.speed or 0, exp = statExp.speed or 0 },
    { label = "SPECIAL", dv = dvs.special or 0, exp = statExp.special or 0 },
  }
end

-- ===========================================================================
-- Shared native (pixel) rendering, used both standalone and via Kanto
-- Reforged's compatibility hook.
-- ===========================================================================

local function drawFallbackHeader(self)
  local Font = require("src.render.Font")
  local HudTiles = require("src.render.HudTiles")
  local mon = self.mon
  local def = self.game.data.pokemon[mon.species]

  if self.sprite then
    local pw, ph = self.sprite:getDimensions()
    local py = math.max(0, 56 - ph)
    love.graphics.draw(self.sprite, 8 + pw, py, 0, -1, 1)
  end
  love.graphics.setColor(0, 0, 0, 1)
  Font.draw(mon.nickname or (def and def.name) or mon.species or "?????", 72, 8)
  HudTiles.statusTile(0x74, 8, 56)
  Font.drawCode(0xF2, 16, 56)
  Font.draw(("%03d"):format(def and def.dex or 0), 24, 56)
end

local function drawStatsBody(self)
  local Font = require("src.render.Font")
  local HudTiles = require("src.render.HudTiles")

  for i = 0, 5 do HudTiles.statusTile(0x78, 152, (8 + i) * 8) end
  HudTiles.statusTile(0x77, 152, 56)
  for i = 1, 10 do HudTiles.statusTile(0x76, 152 - i * 8, 56) end
  HudTiles.statusTile(0x6F, 152 - 88, 56)

  love.graphics.setColor(0, 0, 0, 1)
  Font.drawBox(0, 8, 20, 10)
  Font.draw("IV / EV", 8, 72)
  for i, stat in ipairs(buildStats(self.mon)) do
    local y = 80 + (i - 1) * 8
    local iv = dvToIv(stat.dv)
    local ev = statExpToEv(stat.exp)
    Font.draw(stat.label .. "  " .. tostring(iv) .. "/" .. tostring(ev), 8, y)
  end
  love.graphics.setColor(1, 1, 1, 1)
end

-- `SummaryUi` is Kanto Reforged's own summary_ui module (with a nicer,
-- gender-aware header). When called standalone, it's nil and a basic
-- fallback header is drawn instead.
local function drawSummaryPage(self, SummaryUi)
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.rectangle("fill", 0, 0, 160, 144)
  if SummaryUi and SummaryUi.drawHeader then
    SummaryUi.drawHeader(self)
  else
    drawFallbackHeader(self)
  end
  drawStatsBody(self)
end

-- ===========================================================================
-- Standalone mode: wrap the native SummaryMenu class directly.
-- ===========================================================================

local function installNativePage(mod)
  local ok, Builtin = pcall(require, "src.ui.SummaryMenu")
  if not ok or not Builtin or not Builtin.new then
    mod.log:warn("HiddenStats: src.ui.SummaryMenu unavailable; standalone page skipped")
    return false
  end
  if not (mod.content and mod.content.screens and mod.content.screens.register) then
    mod.log:warn("HiddenStats: content.screens registry unavailable")
    return false
  end

  local baseNew = Builtin.new

  mod.content.screens:register("SummaryMenu", {
    new = function(game, monArg)
      local self = baseNew(game, monArg)
      local basePage = self._expMaxPage or 2
      self._expMaxPage = basePage + 1
      local extraPage = self._expMaxPage

      function self:advance()
        if self.page < self._expMaxPage then
          self.page = self.page + 1
        else
          self.game.stack:pop()
        end
      end

      function self:update(_dt)
        local input = self.game.input
        if input:wasPressed("a") or input:wasPressed("b") then
          self:advance()
        end
      end

      local baseDraw = self.draw
      function self:draw()
        if self.page == extraPage then
          drawSummaryPage(self, nil)
        else
          baseDraw(self)
        end
      end

      return self
    end,
  })
  return true
end

-- ===========================================================================
-- Gen1 Modern UI adapter: contributes only the extra page. gen1_modern_ui
-- already fully models the native pages on its own, so nothing else to add.
-- ===========================================================================

local function installModernUiAdapter(mod)
  local ui = mod.find and mod.find("gen1_modern_ui")
  if not (ui and ui.exports and ui.exports.registerAdapter) then
    return false
  end

  local function matchesExtraPage(state)
    return type(state) == "table"
      and state.screenId == "SummaryMenu"
      and type(state.page) == "number"
      and state.mon ~= nil
      and type(state._expMaxPage) == "number"
      and state._expMaxPage > 2
      and state.page == state._expMaxPage
  end

  local function model(_game, state)
    local rows = {}
    for _, stat in ipairs(buildStats(state.mon)) do
      rows[#rows + 1] = {
        label = stat.label,
        value = ("IV %2d / EV %3d"):format(dvToIv(stat.dv), statExpToEv(stat.exp)),
        enabled = false,
      }
    end
    return {
      title = "IV / EV",
      rows = rows,
      index = 1,
      scroll = 0,
      footer = { ("A/B close  %d/%d"):format(state.page, state._expMaxPage) },
    }
  end

  local function close(_, state)
    return type(state.advance) == "function" and state:advance()
  end

  return ui.exports.registerAdapter({
    owner = mod.id,
    contract = {
      apiVersion = 1,
      screens = {
        HiddenStatsSummary = {
          match = matchesExtraPage,
          model = model,
          actions = { select = close, back = close },
          layer = "screen",
          canSuppressNative = true,
        },
      },
    },
  })
end

-- ===========================================================================

return function(mod)
  -- Always published, so Kanto Reforged's compatibility hook (Phase 2) can
  -- call into this mod regardless of whether standalone mode also ran.
  mod.exports = {
    summaryPageModel = function(mon, _data)
      local rows = {}
      for _, stat in ipairs(buildStats(mon)) do
        rows[#rows + 1] = {
          label = stat.label,
          value = ("IV %2d / EV %3d"):format(dvToIv(stat.dv), statExpToEv(stat.exp)),
          enabled = false,
        }
      end
      return { title = "IV / EV", rows = rows }
    end,
    drawSummaryPage = drawSummaryPage,
  }

  if mod.find and mod.find("Kanto-Reforged") then
    mod.log:info("HiddenStats: Kanto Reforged detected; running in compatibility-only mode")
    return true
  end

  local nativeOk = installNativePage(mod)
  local modernOk = installModernUiAdapter(mod)
  if nativeOk then mod.log:info("HiddenStats: standalone native page installed") end
  if modernOk then mod.log:info("HiddenStats: Gen1 Modern UI page installed") end
  return nativeOk or modernOk
end
