local grid_utils = require("grid_utils")
local emptyGrid  = grid_utils.emptyGrid
local copyGrid   = grid_utils.copyGrid

local function shuffledDigits(n)
    local digits = {}
    for i = 1, n do digits[i] = i end
    for i = n, 2, -1 do
        local j = math.random(i)
        digits[i], digits[j] = digits[j], digits[i]
    end
    return digits
end

local function isValidPlacement(grid, row, col, value, n, box_rows, box_cols)
    for i = 1, n do
        if grid[row][i] == value or grid[i][col] == value then
            return false
        end
    end
    local br = math.floor((row - 1) / box_rows) * box_rows + 1
    local bc = math.floor((col - 1) / box_cols) * box_cols + 1
    for r = br, br + box_rows - 1 do
        for c = bc, bc + box_cols - 1 do
            if grid[r][c] == value then
                return false
            end
        end
    end
    return true
end

local function fillBoard(grid, cell, n, box_rows, box_cols)
    if cell > n * n then
        return true
    end
    local row = math.floor((cell - 1) / n) + 1
    local col = (cell - 1) % n + 1
    local numbers = shuffledDigits(n)
    for _, value in ipairs(numbers) do
        if isValidPlacement(grid, row, col, value, n, box_rows, box_cols) then
            grid[row][col] = value
            if fillBoard(grid, cell + 1, n, box_rows, box_cols) then
                return true
            end
            grid[row][col] = 0
        end
    end
    return false
end

local function generateSolvedBoard(n, box_rows, box_cols)
    local grid = emptyGrid(n)
    fillBoard(grid, 1, n, box_rows, box_cols)
    return grid
end

local function countSolutions(grid, limit, n, box_rows, box_cols)
    local solutions = 0
    local function search(cell)
        if solutions >= limit then return end
        if cell > n * n then
            solutions = solutions + 1
            return
        end
        local row = math.floor((cell - 1) / n) + 1
        local col = (cell - 1) % n + 1
        if grid[row][col] ~= 0 then
            search(cell + 1)
            return
        end
        for _, value in ipairs(shuffledDigits(n)) do
            if isValidPlacement(grid, row, col, value, n, box_rows, box_cols) then
                grid[row][col] = value
                search(cell + 1)
                grid[row][col] = 0
                if solutions >= limit then return end
            end
        end
    end
    search(1)
    return solutions
end

local function createPuzzle(solved_grid, difficulty, n, box_rows, box_cols)
    local puzzle = copyGrid(solved_grid, n)
    local total = n * n
    local ratios = { easy = 0.43, medium = 0.56, hard = 0.65 }
    local ratio = ratios[difficulty] or ratios.medium
    local removals = math.floor(total * ratio)
    local cells = {}
    for r = 1, n do
        for c = 1, n do
            cells[#cells + 1] = { r = r, c = c }
        end
    end
    for i = #cells, 2, -1 do
        local j = math.random(i)
        cells[i], cells[j] = cells[j], cells[i]
    end
    local removed = 0
    for _, cell in ipairs(cells) do
        if removed >= removals then break end
        local row, col = cell.r, cell.c
        if puzzle[row][col] ~= 0 then
            local backup = puzzle[row][col]
            puzzle[row][col] = 0
            local working = copyGrid(puzzle, n)
            if countSolutions(working, 2, n, box_rows, box_cols) == 1 then
                removed = removed + 1
            else
                puzzle[row][col] = backup
            end
        end
    end
    return puzzle
end

return {
    generateSolvedBoard = generateSolvedBoard,
    countSolutions      = countSolutions,
    createPuzzle        = createPuzzle,
}
