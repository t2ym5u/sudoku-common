local ButtonDialog       = require("ui/widget/buttondialog")
local ButtonTable        = require("ui/widget/buttontable")
local Blitbuffer         = require("ffi/blitbuffer")
local Device             = require("device")
local Font               = require("ui/font")
local Geom               = require("ui/geometry")
local InfoMessage        = require("ui/widget/infomessage")
local InputContainer     = require("ui/widget/container/inputcontainer")
local ProgressbarDialog  = require("ui/widget/progressbardialog")
local TextViewer         = require("ui/widget/textviewer")
local TextWidget         = require("ui/widget/textwidget")
local TitleBar           = require("ui/widget/titlebar")
local UIManager          = require("ui/uimanager")
local VerticalGroup      = require("ui/widget/verticalgroup")
local VerticalSpan       = require("ui/widget/verticalspan")
local time               = require("ui/time")
local T                  = require("ffi/util").template

-- sudoku-common is vendored independently into each consuming plugin's own
-- common/ dir (see the sudoku_common family in manifest.json), so it cannot
-- count on game-common's i18n.lua being loaded. Each consuming plugin does
-- ship its own i18n.lua (same callable-plus-lang() shape, and its table
-- already carries this file's strings), so prefer it when it is reachable and
-- fall back to a bare gettext shim when it is not -- without the pcall, every
-- string below would go straight to KOReader's gettext, which knows none of
-- them, and the whole shared UI would stay English on a French device.
local koreader_t = require("gettext")
local function lang()
    return (G_reader_settings and G_reader_settings:readSetting("language") or "en"):sub(1, 2)
end
local ok_i18n, plugin_i18n = pcall(require, "i18n")
local _ = (ok_i18n and type(plugin_i18n) == "table" and plugin_i18n.lang)
    and plugin_i18n
    or setmetatable({ lang = lang }, {
        __call = function(_, s) return koreader_t(s) end,
    })

local DeviceScreen = Device.screen

-- ---------------------------------------------------------------------------
-- Shared difficulty constants
-- ---------------------------------------------------------------------------

local DIFFICULTY_ORDER = { "easy", "medium", "hard", "expert" }
local DIFFICULTY_LABELS = {
    easy   = _("Easy"),
    medium = _("Medium"),
    hard   = _("Hard"),
    expert = _("Expert"),
}

-- ---------------------------------------------------------------------------
-- Puzzle generation with a real progress bar
--
-- board:generate() blocks the UI thread (uniqueness-check backtracking over
-- every dug cell). Rather than a fake timer, we drive a ProgressbarDialog
-- off the actual removed/removals counts board:generate() reports. The
-- dialog only appears once generation has already run past
-- PROGRESS_SHOW_DELAY_MS, so quick generations (small grids, easy
-- difficulty) never get an unnecessary e-ink flash.
-- ---------------------------------------------------------------------------

local PROGRESS_SHOW_DELAY_MS = 200

-- rng (optional): a DailySeed.rng()-style function() -> [0,1) closure, used
-- for reproducible "puzzle of the day" generation (see game-common/daily_seed.lua).
-- Converted here, once, to the randInt(i) -> [1,i] shape puzzle_generator.lua
-- and board:generate() expect. nil means board:generate() falls back to
-- math.random -- normal "New game" play is unaffected.
local function generateWithProgress(board, difficulty, rng)
    local start = time.now()
    local dialog
    local randInt = rng and function(i) return math.floor(rng() * i) + 1 end or nil
    board:generate(difficulty, randInt, function(removed, removals)
        if removals <= 0 then return end
        if not dialog then
            if time.to_ms(time.since(start)) < PROGRESS_SHOW_DELAY_MS then return end
            dialog = ProgressbarDialog:new{
                title                = _("Generating puzzle…"),
                progress_max         = 1,
                refresh_time_seconds = 0.15,
                dismissable          = false,
            }
            dialog:show()
        end
        dialog:reportProgress(removed / removals)
    end)
    if dialog then dialog:close() end
end

-- ---------------------------------------------------------------------------
-- Hints
--
-- A hint is deliberately not "here is the answer". onHint() walks the same
-- logic_solver the generator used, and reveals it in three taps:
--
--   1. where to look   -- names the row/column/box that is about to give
--   2. why             -- names the technique and the digit, and selects the cell
--   3. the value       -- writes it in (undoable like any other move)
--
-- Tapping Hint on an unchanged board advances a level; if the next deduction
-- has moved elsewhere (the player solved that cell themselves, say) it starts
-- again at level 1. That is why the level is derived by comparing the target
-- cell rather than stored as board state -- it cannot go stale.
-- ---------------------------------------------------------------------------

local logic_solver = require("logic_solver")

-- Digits above 9 render as A-G, matching base_board_widget and the keypad.
local function digitToChar(d)
    return d <= 9 and tostring(d) or string.char(55 + d)
end

-- Named for the player, not for the solver: the point of mentioning the
-- technique is that it is something they can learn to spot next time.
local TECHNIQUE_LABELS = {
    locked_candidates = _("locked candidates"),
    naked_pair        = _("a naked pair"),
    hidden_pair       = _("a hidden pair"),
    naked_triple      = _("a naked triple"),
    hidden_triple     = _("a hidden triple"),
    naked_quad        = _("a naked quad"),
    x_wing            = _("an X-Wing"),
    swordfish         = _("a Swordfish"),
    xy_wing           = _("an XY-Wing"),
}

-- ---------------------------------------------------------------------------
-- BaseScreen — shared full-screen game UI
--
-- Subclasses must implement:
--   :buildLayout()           — create board widget + button tables + self.layout
--   :getDifficultyButtonText() — returns localized string for difficulty button
--   :openDifficultyMenu()    — shows difficulty picker
--   :updateStatus([msg])     — refreshes status bar text
-- ---------------------------------------------------------------------------

local BaseScreen = InputContainer:extend{}

function BaseScreen:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = DeviceScreen:getWidth(), h = DeviceScreen:getHeight() }
    self.covers_fullscreen = true
    self.vertical_align    = "center"
    self.note_mode         = false
    self.undo_button       = nil
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end
    self.status_text = TextWidget:new{
        text = _("Tap a cell, then pick a number."),
        face = Font:getFace("smallinfofont"),
    }
    self:buildLayout()
    UIManager:setDirty(self, function()
        return "ui", self.dimen
    end)
end

function BaseScreen:paintTo(bb, x, y)
    self.dimen.x = x
    self.dimen.y = y
    bb:paintRect(x, y, self.dimen.w, self.dimen.h, Blitbuffer.COLOR_WHITE)
    local content_size = self.layout:getSize()
    local offset_x = x + math.floor((self.dimen.w - content_size.w) / 2)
    local offset_y = y
    if self.vertical_align == "center" then
        offset_y = offset_y + math.floor((self.dimen.h - content_size.h) / 2)
    end
    self.layout:paintTo(bb, offset_x, offset_y)
end

-- ---------------------------------------------------------------------------
-- Button text helpers
-- ---------------------------------------------------------------------------

function BaseScreen:getNoteButtonText()
    return self.note_mode and _("Note: On") or _("Note: Off")
end

-- ---------------------------------------------------------------------------
-- Button update helpers
-- ---------------------------------------------------------------------------

function BaseScreen:updateNoteButton()
    if not self.note_button then return end
    self.note_button:setText(self:getNoteButtonText(), self.note_button.width)
end

function BaseScreen:updateUndoButton()
    if not self.undo_button then return end
    self.undo_button:enableDisable(self.board:canUndo())
end

function BaseScreen:updateDigitButtons()
    if not self.digit_buttons then return end
    local n = self.board.n
    for d = 1, n do
        local btn = self.digit_buttons[d]
        if btn then
            btn:enableDisable(self.board:countDigit(d) < n)
        end
    end
end

function BaseScreen:updateDifficultyButton()
    if not self.difficulty_button then return end
    self.difficulty_button:setText(self:getDifficultyButtonText(), self.difficulty_button.width)
end

-- ---------------------------------------------------------------------------
-- Mode toggles
-- ---------------------------------------------------------------------------

function BaseScreen:toggleNoteMode()
    self.note_mode = not self.note_mode
    self:updateNoteButton()
    self:updateStatus(self.note_mode and _("Note mode enabled.") or _("Note mode disabled."))
end

-- ---------------------------------------------------------------------------
-- Game actions
-- ---------------------------------------------------------------------------

function BaseScreen:onDigit(value)
    if self.note_mode then
        local ok, err = self.board:toggleNoteDigit(value)
        if not ok then
            self:updateStatus(err)
            return
        end
        self.board_widget:refresh()
        self:updateStatus()
        self.plugin:saveState()
        self:updateUndoButton()
        return
    end
    local ok, err = self.board:setValue(value)
    if not ok then
        self:updateStatus(err)
        return
    end
    self.board_widget:refresh()
    self:updateStatus()
    self.plugin:saveState()
    self:updateUndoButton()
    self:updateDigitButtons()
    if self.board:isSolved() then
        UIManager:show(InfoMessage:new{ text = _("Puzzle complete!"), timeout = 4 })
    end
end

function BaseScreen:onErase()
    local row, col = self.board:getSelection()
    self.board:clearNotes(row, col)
    local ok, err = self.board:clearSelection()
    if not ok then
        self:updateStatus(err)
        return
    end
    self.board_widget:refresh()
    self:updateStatus()
    self.plugin:saveState()
    self:updateUndoButton()
    self:updateDigitButtons()
end

function BaseScreen:onNewGame()
    generateWithProgress(self.board, self.board.difficulty)
    self.board:resetHintsUsed()
    self.hint_cell = nil
    self.plugin:saveState()
    self.board_widget:refresh()
    self:ensureShowButtonState()
    self:updateUndoButton()
    self:updateDigitButtons()
    self:updateStatus(_("Started a new game."))
end

function BaseScreen:toggleSolution()
    self.board:toggleSolution()
    self.plugin:saveState()
    self.board_widget:refresh()
    self:ensureShowButtonState()
    self:updateStatus(self.board:isShowingSolution() and _("Showing the solution.") or nil)
end

function BaseScreen:ensureShowButtonState()
    if not self.show_result_button then return end
    local text = self.board:isShowingSolution() and _("Hide result") or _("Show result")
    self.show_result_button:setText(text, self.show_result_button.width)
end

function BaseScreen:checkProgress()
    self.board:updateWrongMarks()
    self.board_widget:refresh()
    self.plugin:saveState()
    if self.board:isSolved() then
        self:updateStatus(_("Everything looks good!"))
    elseif self.board:getRemainingCells() == 0 then
        self:updateStatus(_("There are mistakes highlighted in red."))
    else
        self:updateStatus(_("Keep going!"))
    end
end

-- ---------------------------------------------------------------------------
-- Hint button
-- ---------------------------------------------------------------------------

-- Level 1: point at the unit that is about to give, without saying what.
function BaseScreen:describeHintArea(step, cell)
    local kind = step.unit_kind
    if kind == "row" then
        return T(_("There is a cell you can solve in row %1."), cell.r)
    elseif kind == "col" then
        return T(_("There is a cell you can solve in column %1."), cell.c)
    elseif kind == "box" then
        return T(_("There is a cell you can solve in the box around R%1C%2."), cell.r, cell.c)
    elseif kind == "region" then
        return T(_("There is a cell you can solve in the shaded region around R%1C%2."), cell.r, cell.c)
    end
    -- naked_single: no single unit justifies it, the cell itself is the answer
    return T(_("There is a cell you can solve in row %1."), cell.r)
end

-- Level 2: name the technique and the digit. The prerequisite, when there is
-- one, is the interesting part -- it is what the player had to spot to get a
-- placement at all -- so mention the hardest one rather than the first.
function BaseScreen:describeHintReason(step, prereq, cell)
    local msg
    local digit = digitToChar(cell.digit)
    if step.technique == "naked_single" then
        msg = T(_("R%1C%2 has only one value left."), cell.r, cell.c)
    elseif step.unit_kind == "row" then
        msg = T(_("%1 fits in only one cell of row %2."), digit, cell.r)
    elseif step.unit_kind == "col" then
        msg = T(_("%1 fits in only one cell of column %2."), digit, cell.c)
    elseif step.unit_kind == "region" then
        msg = T(_("%1 fits in only one cell of that region."), digit)
    else
        msg = T(_("%1 fits in only one cell of that box."), digit)
    end
    local hardest
    for _idx = 1, #prereq do
        local candidate = prereq[_idx]
        if not hardest or candidate.tier > hardest.tier then hardest = candidate end
    end
    local label = hardest and TECHNIQUE_LABELS[hardest.technique]
    if label then
        msg = msg .. " " .. T(_("You need %1 first."), label)
    end
    return msg
end

function BaseScreen:onHint()
    local board = self.board
    if board:isShowingSolution() then
        self:updateStatus(_("Hide result to keep playing."))
        return
    end
    if board:findWrongEntry() then
        self.hint_cell = nil
        self:updateStatus(_("There is a wrong value on the board."))
        return
    end

    local step, prereq, reason = logic_solver.nextPlacement(
        board:getWorkingGrid(), board.n, board.box_rows, board.box_cols,
        board:getExtraRegions(), { cages = board:getCages() })

    if not step then
        self.hint_cell = nil
        if reason == "complete" then
            self:updateStatus(_("Nothing left to fill in."))
        else
            -- Grids from puzzle_generator are deducible by construction, so
            -- this is reachable only for variants generating their own puzzles
            -- (sudokukiller's cage layouts) or from a contradictory board.
            self:updateStatus(_("No purely logical step is available here."))
        end
        return
    end

    local cell = step.placements[1]
    local prev = self.hint_cell
    local same = prev and prev.r == cell.r and prev.c == cell.c and prev.digit == cell.digit
    local level = same and (prev.level + 1) or 1
    self.hint_cell = { r = cell.r, c = cell.c, digit = cell.digit, level = level }

    if level == 1 then
        self:updateStatus(self:describeHintArea(step, cell))
        return
    end
    if level == 2 then
        board:setSelection(cell.r, cell.c)
        self.board_widget:refresh()
        self:updateStatus(self:describeHintReason(step, prereq, cell))
        return
    end

    local ok, err = board:applyHint(cell.r, cell.c, cell.digit)
    self.hint_cell = nil
    if not ok then
        self:updateStatus(err)
        return
    end
    self.board_widget:refresh()
    self.plugin:saveState()
    self:updateUndoButton()
    self:updateDigitButtons()
    self:updateStatus(T(_("R%1C%2 = %3. Hints used: %4."),
        cell.r, cell.c, digitToChar(cell.digit), board:getHintsUsed()))
    if board:isSolved() then
        UIManager:show(InfoMessage:new{ text = _("Puzzle complete!"), timeout = 4 })
    end
end

function BaseScreen:closeScreen()
    self.plugin:saveState()
    self.plugin:onScreenClosed()
    UIManager:close(self)
    UIManager:setDirty(nil, "full")
end

function BaseScreen:onClose()
    self:closeScreen()
end

function BaseScreen:makeCloseButtonConfig()
    return {
        text     = _("Close"),
        callback = function() self:closeScreen() end,
    }
end

function BaseScreen:onUndo()
    local ok, err = self.board:undo()
    if not ok then
        self:updateStatus(err)
        return
    end
    self.board_widget:refresh()
    self:updateStatus(_("Last move undone."))
    self.plugin:saveState()
    self:updateUndoButton()
    self:updateDigitButtons()
end

-- ---------------------------------------------------------------------------
-- TitleBar helpers
-- ---------------------------------------------------------------------------

function BaseScreen:buildTitleBar(title, options_fn)
    local self_ref = self
    return TitleBar:new{
        width                  = DeviceScreen:getWidth(),
        title                  = title,
        left_icon              = "appbar.menu",
        left_icon_tap_callback = function()
            local dlg
            local buttons = {}
            for _, item in ipairs(options_fn()) do
                local cb = item.callback
                buttons[#buttons + 1] = {{ text = item.text, callback = function()
                    UIManager:close(dlg)
                    cb()
                end }}
            end
            dlg = ButtonDialog:new{ title = title, buttons = buttons }
            UIManager:show(dlg)
        end,
        close_callback = function() self_ref:closeScreen() end,
        with_bottom_line = true,
    }
end

function BaseScreen:buildLandscapeLayout(title_bar, content)
    local sh       = self.dimen.h
    local tb_h     = title_bar:getSize().h
    local avail_h  = sh - tb_h
    local cont_h   = content:getSize().h
    local top_span = math.max(0, math.floor((avail_h - cont_h) / 2))
    local bot_span = math.max(0, avail_h - top_span - cont_h)
    self.layout = VerticalGroup:new{
        title_bar,
        VerticalSpan:new{ width = top_span },
        content,
        VerticalSpan:new{ width = bot_span },
    }
    self[1] = self.layout
end

-- ---------------------------------------------------------------------------
-- Fixed portrait layout helper
-- ---------------------------------------------------------------------------

function BaseScreen:buildPortraitLayout(header, content, footer)
    local sh       = self.dimen.h
    local header_h = header  and header:getSize().h  or 0
    local content_h= content and content:getSize().h or 0
    local footer_h = footer  and footer:getSize().h  or 0
    local remaining = math.max(0, sh - header_h - content_h - footer_h)
    local top_gap   = math.floor(remaining / 2)
    local bot_gap   = remaining - top_gap
    local items = { align = "center" }
    if header  then items[#items+1] = header  end
    items[#items+1] = VerticalSpan:new{ width = top_gap }
    if content then items[#items+1] = content end
    items[#items+1] = VerticalSpan:new{ width = bot_gap }
    if footer  then items[#items+1] = footer  end
    self.layout = VerticalGroup:new(items)
    self[1] = self.layout
end

-- ---------------------------------------------------------------------------
-- Rules dialog (for use in ButtonTable rows)
-- ---------------------------------------------------------------------------

function BaseScreen:showRules(text)
    UIManager:show(TextViewer:new{
        title  = _("Rules"),
        text   = text,
        width  = math.floor(DeviceScreen:getWidth() * 0.9),
        height = math.floor(DeviceScreen:getHeight() * 0.9),
    })
end

function BaseScreen:makeRulesButtonConfig(en_text, fr_text)
    return {
        text     = _("Rules"),
        callback = function()
            self:showRules((_.lang() == "fr" and fr_text) or en_text)
        end,
    }
end

return {
    BaseScreen           = BaseScreen,
    digitToChar          = digitToChar,
    DIFFICULTY_ORDER     = DIFFICULTY_ORDER,
    DIFFICULTY_LABELS    = DIFFICULTY_LABELS,
    generateWithProgress = generateWithProgress,
}
