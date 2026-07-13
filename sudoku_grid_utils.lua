local function emptyGrid(n)
    local grid = {}
    for r = 1, n do
        grid[r] = {}
        for c = 1, n do
            grid[r][c] = 0
        end
    end
    return grid
end

local function copyGrid(src, n)
    local grid = {}
    for r = 1, n do
        grid[r] = {}
        for c = 1, n do
            grid[r][c] = src[r][c]
        end
    end
    return grid
end

local function emptyNotes(n)
    local notes = {}
    for r = 1, n do
        notes[r] = {}
        for c = 1, n do
            notes[r][c] = {}
        end
    end
    return notes
end

local function emptyMarkerGrid(n)
    local grid = {}
    for r = 1, n do
        grid[r] = {}
        for c = 1, n do
            grid[r][c] = false
        end
    end
    return grid
end

local function cloneNoteCell(cell)
    if not cell then
        return nil
    end
    local copy = nil
    for digit = 1, 16 do
        if cell[digit] then
            copy = copy or {}
            copy[digit] = true
        end
    end
    return copy
end

local function copyNotes(src, n)
    local notes = {}
    for r = 1, n do
        notes[r] = {}
        for c = 1, n do
            local dest_cell = {}
            local source_cell = src and src[r] and src[r][c]
            if type(source_cell) == "table" then
                local had_array_values = false
                for _, digit in ipairs(source_cell) do
                    local d = tonumber(digit)
                    if d and d >= 1 and d <= n then
                        dest_cell[d] = true
                        had_array_values = true
                    end
                end
                if not had_array_values then
                    for digit, flag in pairs(source_cell) do
                        local d = tonumber(digit)
                        if d and d >= 1 and d <= n and flag then
                            dest_cell[d] = true
                        end
                    end
                end
            end
            notes[r][c] = dest_cell
        end
    end
    return notes
end

return {
    emptyGrid       = emptyGrid,
    copyGrid        = copyGrid,
    emptyNotes      = emptyNotes,
    emptyMarkerGrid = emptyMarkerGrid,
    cloneNoteCell   = cloneNoteCell,
    copyNotes       = copyNotes,
}
