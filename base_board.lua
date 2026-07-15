local _ = require("gettext")
local grid_utils    = require("sudoku_grid_utils")
local cloneNoteCell = grid_utils.cloneNoteCell

-- ---------------------------------------------------------------------------
-- BaseBoard — common game state and logic for all sudoku variants
--
-- Subclasses must implement:
--   :new()           — constructor
--   :serialize()     — save state to table
--   :load(state)     — restore from table, return bool
--   :generate(diff)  — create a new puzzle
--   :isGiven(r,c)    — true if cell is pre-filled (not user-editable)
--   :getWorkingValue(r,c)   — displayed/effective cell value
--   :getDisplayValue(r,c)   — (value, is_given) for rendering
--
-- Subclasses may override:
--   :recalcConflicts() — extend with variant-specific conflict rules
-- ---------------------------------------------------------------------------

local BaseBoard = {}
BaseBoard.__index = BaseBoard

local function ensureGridValues(grid, n)
    for r = 1, n do
        grid[r] = grid[r] or {}
        for c = 1, n do
            grid[r][c] = grid[r][c] or 0
        end
    end
end

-- Row / column / box conflict detection.
-- Killer sudoku overrides this to also check cage duplicates.
function BaseBoard:recalcConflicts()
    local n, box_rows, box_cols = self.n, self.box_rows, self.box_cols
    ensureGridValues(self.conflicts, n)
    for r = 1, n do
        for c = 1, n do
            self.conflicts[r][c] = false
        end
    end
    local function markConflicts(cells)
        local map = {}
        for _, cell in ipairs(cells) do
            if cell.value ~= 0 then
                map[cell.value] = map[cell.value] or {}
                table.insert(map[cell.value], cell)
            end
        end
        for _, positions in pairs(map) do
            if #positions > 1 then
                for _, pos in ipairs(positions) do
                    self.conflicts[pos.row][pos.col] = true
                end
            end
        end
    end
    for r = 1, n do
        local cells = {}
        for c = 1, n do
            cells[#cells + 1] = { row = r, col = c, value = self:getWorkingValue(r, c) }
        end
        markConflicts(cells)
    end
    for c = 1, n do
        local cells = {}
        for r = 1, n do
            cells[#cells + 1] = { row = r, col = c, value = self:getWorkingValue(r, c) }
        end
        markConflicts(cells)
    end
    local num_box_rows = math.floor(n / box_rows)
    local num_box_cols = math.floor(n / box_cols)
    for box_r = 0, num_box_rows - 1 do
        for box_c = 0, num_box_cols - 1 do
            local cells = {}
            for r = 1, box_rows do
                for c = 1, box_cols do
                    local row = box_r * box_rows + r
                    local col = box_c * box_cols + c
                    cells[#cells + 1] = { row = row, col = col, value = self:getWorkingValue(row, col) }
                end
            end
            markConflicts(cells)
        end
    end
end

function BaseBoard:setSelection(row, col)
    local n = self.n
    self.selected = { row = math.max(1, math.min(n, row)), col = math.max(1, math.min(n, col)) }
end

function BaseBoard:getSelection()
    return self.selected.row, self.selected.col
end

function BaseBoard:isShowingSolution()
    return self.reveal_solution
end

function BaseBoard:toggleSolution()
    self.reveal_solution = not self.reveal_solution
end

function BaseBoard:setValue(value)
    if self.reveal_solution then
        return false, _("Hide result to keep playing.")
    end
    local row, col = self:getSelection()
    if self:isGiven(row, col) then
        return false, _("This cell is fixed.")
    end
    local prev_value = self.user[row][col]
    local prev_notes = cloneNoteCell(self.notes[row][col])
    local new_value  = value or 0

    if prev_value == new_value and not prev_notes then
        if not value then
            return false, _("Cell already empty.")
        end
        return true
    end

    self.user[row][col] = new_value
    self:clearNotes(row, col)
    self:clearWrongMark(row, col)
    self:recalcConflicts()
    if prev_value ~= new_value or prev_notes then
        self:pushUndo{
            type       = "value",
            row        = row,
            col        = col,
            prev_value = prev_value,
            prev_notes = prev_notes,
        }
    end
    return true
end

function BaseBoard:clearSelection()
    return self:setValue(nil)
end

function BaseBoard:clearNotes(row, col)
    if self.notes[row] and self.notes[row][col] then
        self.notes[row][col] = {}
    end
end

function BaseBoard:getCellNotes(row, col)
    local cell = self.notes[row] and self.notes[row][col]
    if not cell then return nil end
    for digit = 1, self.n do
        if cell[digit] then return cell end
    end
    return nil
end

function BaseBoard:clearWrongMarks()
    for r = 1, self.n do
        for c = 1, self.n do
            self.wrong_marks[r][c] = false
        end
    end
end

function BaseBoard:clearWrongMark(row, col)
    if self.wrong_marks[row] then
        self.wrong_marks[row][col] = false
    end
end

function BaseBoard:hasWrongMark(row, col)
    return self.wrong_marks[row] and self.wrong_marks[row][col] or false
end

function BaseBoard:updateWrongMarks()
    self:clearWrongMarks()
    local has_wrong = false
    for r = 1, self.n do
        for c = 1, self.n do
            local value = self.user[r][c]
            if value ~= 0 and value ~= self.solution[r][c] then
                self.wrong_marks[r][c] = true
                has_wrong = true
            end
        end
    end
    return has_wrong
end

function BaseBoard:toggleNoteDigit(value)
    if self.reveal_solution then
        return false, _("Hide result to keep playing.")
    end
    local row, col = self:getSelection()
    if self:isGiven(row, col) then
        return false, _("This cell is fixed.")
    end
    if self.user[row][col] ~= 0 then
        return false, _("Clear the cell before adding notes.")
    end
    self.notes[row][col] = self.notes[row][col] or {}
    local prev_cell = cloneNoteCell(self.notes[row][col])
    local was_set   = self.notes[row][col][value] and true or false
    if was_set then
        self.notes[row][col][value] = nil
    else
        self.notes[row][col][value] = true
    end
    local now_set = self.notes[row][col][value] and true or false
    if was_set == now_set then return true end
    self:pushUndo{
        type       = "notes",
        row        = row,
        col        = col,
        prev_notes = prev_cell,
    }
    return true
end

function BaseBoard:getRemainingCells()
    local remaining = 0
    for r = 1, self.n do
        for c = 1, self.n do
            if self:getWorkingValue(r, c) == 0 then
                remaining = remaining + 1
            end
        end
    end
    return remaining
end

function BaseBoard:countDigit(digit)
    local count = 0
    for r = 1, self.n do
        for c = 1, self.n do
            if self:getWorkingValue(r, c) == digit then
                count = count + 1
            end
        end
    end
    return count
end

function BaseBoard:pushUndo(entry)
    if entry then
        self.undo_stack[#self.undo_stack + 1] = entry
    end
end

function BaseBoard:canUndo()
    return self.undo_stack[1] ~= nil
end

function BaseBoard:undo()
    local entry = table.remove(self.undo_stack)
    if not entry then
        return false, _("Nothing to undo.")
    end
    local row, col = entry.row, entry.col
    if entry.type == "value" then
        self.user[row][col] = entry.prev_value or 0
        self.notes[row][col] = cloneNoteCell(entry.prev_notes) or {}
        self:setSelection(row, col)
        self:recalcConflicts()
        self:clearWrongMark(row, col)
    elseif entry.type == "notes" then
        self.notes[row][col] = cloneNoteCell(entry.prev_notes) or {}
        self:setSelection(row, col)
    end
    return true
end

function BaseBoard:isSolved()
    if self.reveal_solution then return false end
    for r = 1, self.n do
        for c = 1, self.n do
            if self:getWorkingValue(r, c) ~= self.solution[r][c] or self.conflicts[r][c] then
                return false
            end
        end
    end
    return true
end

return BaseBoard
