-- VProbeOnce.hs — drop into bsc/src/comp/
--
-- Post-processes the generated Verilog string (AFTER pp80 vprog has been
-- called in bsc.hs, BEFORE writeVFileCatch writes it to disk) to make
-- every PROBE_ $display fire at most once per simulation run.
--
-- For each probe number N found in any $display("...PROBE_N_...") call:
--   1. Declares  reg probe_fired_N = 0;  (inserted before the first
--      `always` block in the module, which is where BSC puts its clocked
--      logic and where the $display calls live)
--   2. Wraps the innermost $display line with:
--        if (!probe_fired_N) begin
--            $display("...");
--            probe_fired_N <= 1;
--        end
--
-- The existing outer if-guards (WILL_FIRE_*, EN_*, RST_N != ...) are
-- left completely untouched -- only the $display statement itself is
-- wrapped. This means the outer condition still gates when the probe
-- CAN fire, and the inner !probe_fired_N gate ensures it only DOES fire
-- the very first time that outer condition is true.
--
-- bsc.hs patch (unified diff):
-- --- a/src/comp/bsc.hs
-- +++ b/src/comp/bsc.hs
-- @@ import VVerilogDollar
-- +import VProbeOnce(instrumentProbeOnce)
-- @@
-- -       let vstring = comment ++ pp80 vprog
-- +       let vstring = instrumentProbeOnce (comment ++ pp80 vprog)

module VProbeOnce (instrumentProbeOnce) where

import Data.List     (isPrefixOf, isInfixOf, nub, sort)
import Data.Char     (isDigit, isSpace)
import Data.Maybe    (mapMaybe)

-- ============================================================
-- Entry point
-- ============================================================

instrumentProbeOnce :: String -> String
instrumentProbeOnce vstring =
    let ls        = lines vstring
        -- collect all distinct probe numbers from $display lines
        probeNums = nub $ sort $ mapMaybe extractProbeNum ls
        -- wrap each $display line with the once-only latch guard
        ls'       = map wrapDisplayLine ls
        -- insert reg declarations before the first always block
        ls''      = insertDecls probeNums ls'
    in  unlines ls''

-- ============================================================
-- Probe detection
-- ============================================================

-- | True iff this line (after stripping leading whitespace) is a
-- $display call whose format string contains PROBE_.
-- Guards against matching comment lines that happen to mention PROBE_.
isProbeDisplay :: String -> Bool
isProbeDisplay line =
    let s = dropWhile isSpace line
    in  "$display(" `isPrefixOf` s && "PROBE_" `isInfixOf` s

-- | Extract the probe number N from a PROBE_N_ occurrence in the line.
-- Returns Nothing for non-probe lines.
extractProbeNum :: String -> Maybe Int
extractProbeNum line
    | not (isProbeDisplay line) = Nothing
    | otherwise = case findProbeNums line of
        []    -> Nothing
        (n:_) -> Just n

-- | Find all PROBE_N occurrences in a string, returning the list of Ns.
findProbeNums :: String -> [Int]
findProbeNums []         = []
findProbeNums s@(_:rest)
    | "PROBE_" `isPrefixOf` s =
        let digits = takeWhile isDigit (drop 6 s)  -- drop "PROBE_"
        in  if null digits
            then findProbeNums rest
            else read digits : findProbeNums rest
    | otherwise = findProbeNums rest

-- ============================================================
-- Line wrapper
-- ============================================================

-- | Wrap a probe $display line with the once-only latch guard.
-- Preserves the original indentation so the output Verilog stays tidy.
--
-- Before:
--     $display("src/stage3.bsv:PROBE_30_RL_foo_RULE_FIRED");
--
-- After:
--     if (!probe_fired_30) begin
--         $display("src/stage3.bsv:PROBE_30_RL_foo_RULE_FIRED");
--         probe_fired_30 <= 1;
--     end
wrapDisplayLine :: String -> String
wrapDisplayLine line
    | not (isProbeDisplay line) = line
    | otherwise = case findProbeNums line of
        []    -> line
        (n:_) ->
            let indent  = takeWhile isSpace line
                content = dropWhile isSpace line
                reg     = "probe_fired_" ++ show n
            in  indent ++ "if (!" ++ reg ++ ") begin\n"  ++
                indent ++ "    " ++ content              ++ "\n" ++
                indent ++ "    " ++ reg ++ " <= 1;\n"    ++
                indent ++ "end"

-- ============================================================
-- Declaration insertion
-- ============================================================

-- | Insert  reg probe_fired_N = 0;  declarations for every probe number
-- into the Verilog text, placed immediately before the first `always`
-- block. BSC places all clocked logic (including the $display calls) in
-- always blocks, so inserting here puts the declarations in the right
-- scope while keeping them visually grouped.
insertDecls :: [Int] -> [String] -> [String]
insertDecls []   ls = ls
insertDecls nums ls = go ls
  where
    decls = map makeDecl nums ++ [""]

    makeDecl n = "  reg probe_fired_" ++ show n ++ " = 0;"

    go [] = decls  -- fallback: append at end if no always block found
    go (l:rest)
        | "always" `isPrefixOf` dropWhile isSpace l =
            -- insert all declarations, blank line, then the always block
            decls ++ l : rest
        | otherwise =
            l : go rest
