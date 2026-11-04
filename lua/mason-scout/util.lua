-- lua/mason-scout/util.lua
--
-- Shared utility functions for MasonScout.

local M = {}

local MAX_SPREAD = 2 -- subsequence window <= keyword length * MAX_SPREAD

--- Subsequence match (both strings must already be lowercase).
--- 1. Forward pass finds the earliest end of a match.
--- 2. Backward pass from that end finds the tightest window, so contiguous
---    runs score higher than scattered matches.
--- Scoring: +1 per char, +1 per adjacent pair, +3 if the window starts at 1.
--- Returns nil when there is no match or the window is too spread out.
---@param text string text to search within (already lowercase)
---@param pattern string non-empty pattern (already lowercase)
---@return integer|nil score higher is better, or nil when no match
M.fuzzy_match = function(text, pattern)
    local plen, tlen = #pattern, #text
    if plen > tlen then
        return nil
    end

    local pi, last = 1, 0
    local pb = pattern:byte(1)
    for ti = 1, tlen do
        if text:byte(ti) == pb then
            pi = pi + 1
            if pi > plen then
                last = ti
                break
            end
            pb = pattern:byte(pi)
        end
    end
    if last == 0 then
        return nil
    end

    local score, prev, ti = 0, nil, last
    for p = plen, 1, -1 do
        local b = pattern:byte(p)
        while text:byte(ti) ~= b do
            ti = ti - 1
        end
        score = score + 1
        if prev and ti == prev - 1 then
            score = score + 1
        end
        prev = ti
        ti = ti - 1
    end

    local start = prev ---@cast start integer
    if last - start + 1 > plen * MAX_SPREAD then
        return nil
    end

    if start == 1 then
        score = score + 3
    end
    return score
end

return M
