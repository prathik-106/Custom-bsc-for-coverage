-- ICoverage.hs  — drop into  bsc/src/comp/
--
-- Branch-coverage instrumentation pass.
-- Inserts  $display("PROBE_<n>")  at every reachable decision point
-- in rules and Action/ActionValue method bodies.
--
-- Runs AFTER iSplitIf, BEFORE iLift.  Pure function; threads an Int
-- counter so probe IDs are unique and imod_ffcallNo stays consistent.
--
-- See bsc.hs patch at the bottom of this file.
--
-- CHANGELOG (this revision):
--   * DefEnv lookups in renderCond now compare by Id identity
--     (`k == vid`) instead of by base-string equality. The old
--     string-based lookup could silently pick the wrong binding if two
--     distinct synthesized defs ever shared a base string (plausible
--     given how aggressively names get mangled, e.g. the fn_bru\255
--     -style suffixes already observed in output). This is a
--     correctness fix, not just a refactor: a wrong lookup would
--     previously cause renderCond to print a condition that describes
--     a different expression than the one actually gating the branch,
--     without any visible failure.
--
--   * REVERTED in this revision: an earlier attempt at this file added
--     findCondPos/condPosSuffix to append a per-condition " @file:line"
--     source-position annotation to each probe label, going beyond the
--     existing rule-level "_L<n>" in the label. This was removed after
--     testing on StressTest.bsv showed it does not work: getIdPosition
--     on a register/signal Id returns that Id's DECLARATION position,
--     not the position of the particular use-site/condition being
--     instrumented. Every probe referencing the same signal (e.g. "sel")
--     across many different rules all reported the identical line (the
--     mkReg declaration), regardless of which rule or which line inside
--     it the condition actually appeared on -- confirmed misleading,
--     not just imprecise. Investigation into bsc internals (the
--     existing-but-commented-out getIExprPosition/
--     getIExprPositionCrossInternal in ISyntax.hs, and the i_sel
--     position usage in ISplitIf.hs, which is special-cased only for
--     PrimArrayDynSelect out-of-bounds diagnostics) confirmed no
--     per-use-site position survives anywhere in the IR by the time
--     this pass runs; it is discarded upstream during elaboration. A
--     correct fix would require threading position forward from
--     CSyntax/parse time, which is out of scope for this pass. The
--     existing rule-level "_L<n>" label (which IS reliable -- it's the
--     position of the rule's own Id) remains the only source-line
--     annotation in this revision.
module ICoverage (iInstrumentCoverage) where
import ISyntax
import ISyntaxUtil
    ( ieJoinA
    , itAction, itString, itFun
    , isActionType, iGetType
    , iMkString
    )
import Id      (Id, getIdBaseString, getIdPosition)
import Position (getPositionLine, getPositionFile)
import FileNameUtil (getRelativeFilePath)
import Prim    (PrimOp(PrimIf, PrimJoinActions, PrimNoActions))
import PreIds  (idDisplay)
import Debug.Trace (trace)
import Data.List (intercalate)
import Data.Char (isAlphaNum, isAscii)
-- ============================================================
-- Def environment  (recovers original names for renderCond)
-- ============================================================
--
-- `imod_local_defs` is a top-level list of `IDef Id IType (IExpr a) [DefProp]`
-- — i.e. `id := expr` bindings — already sitting on the IModule this pass
-- receives directly. The generic "b__hNNNN" condition variables seen in
-- compiled output are entries in THIS list, not lambda-bound names buried
-- in the rule body (confirmed: ISplitIf.hs introduces no ILam redexes, and
-- IVar/ILam are noted in ISyntax.hs as vanishing at IExpand, an earlier
-- stage — so an IVar surviving to this pass must be referencing something
-- outside the local expression tree, namely this def list). Building a
-- lookup table here and threading it into renderCond lets us recurse
-- through "b" to the actual "s03 == 0" it was bound to, rather than
-- printing the synthesized intermediate name.
type DefEnv a = [(Id, IExpr a)]
mkDefEnv :: IModule a -> DefEnv a
mkDefEnv imod = [ (i, e) | IDef i _ e _ <- imod_local_defs imod ]
-- ============================================================
-- Entry point
-- ============================================================
iInstrumentCoverage :: IModule a -> IModule a
iInstrumentCoverage imod =
    let modName = filter (\c -> (isAscii c && isAlphaNum c) || c == '_')
                         (getIdBaseString (imod_name imod)) in
    trace ("iInstrumentCoverage: ENTRY, imod_name = " ++ modName) $
    let env          = mkDefEnv imod
        n0           = imod_ffcallNo imod
        (rules', n1) = instrRules modName env n0 (imod_rules imod)
        (iface', n2) = instrIface modName env n1 (imod_interface imod)
    in  length iface' `seq`
        imod { imod_rules     = rules'
             , imod_interface = iface'
             , imod_ffcallNo  = n2
             }
-- ============================================================
-- Rules
-- ============================================================
instrRules :: String -> DefEnv a -> Int -> IRules a -> (IRules a, Int)
instrRules modName env n (IRules pragmas rules) =
    trace ("instrRules: got " ++ show (length rules) ++ " rules") $
    let go []     acc k = (reverse acc, k)
        go (r:rs) acc k =
            let before = irule_body r
                rId    = irule_name r
                pos    = getIdPosition rId
                file   = getRelativeFilePath (getPositionFile pos)
                label  = file ++ ":" ++ modName ++ "_" ++ getIdBaseString rId ++
                         "_L" ++ show (getPositionLine pos)
                (body', k')        = trace ("instrRules: calling instrExpr on rule " ++ label) $
                                      instrExpr env True label k before
                -- Rule-fired probe: joined onto the (already branch-
                -- instrumented) body via ieJoinA, the SAME mechanism the
                -- _then/_else probes use. This means it inherits the
                -- exact same "only fires if this rule actually commits"
                -- semantics — no separate guard/predicate wiring needed,
                -- since PrimJoinActions only executes its children when
                -- the surrounding action is scheduled to fire.
                (firedProbe, k'')  = mkProbe env (label ++ "_RULE_FIRED") k'
                bodyFinal          = ieJoinA firedProbe body'
            in  bodyFinal `seq` go rs (r { irule_body = bodyFinal } : acc) k''
        (rules', n') = go rules [] n
    in  length rules' `seq` (IRules pragmas rules', n')
instrRulesWithLabel :: DefEnv a -> String -> Int -> IRules a -> (IRules a, Int)
instrRulesWithLabel env label n (IRules pragmas rules) =
    trace ("instrRulesWithLabel: label=" ++ label ++
           ", got " ++ show (length rules) ++ " rules") $
    let go []     acc k = (reverse acc, k)
        go (r:rs) acc k =
            let before  = irule_body r
                (body', k')       = instrExpr env True label k before
                -- Method-fired probe — same ieJoinA commit-semantics as
                -- the rule-fired probe above (see comment there).
                (firedProbe, k'') = mkProbe env (label ++ "_METHOD_FIRED") k'
                bodyFinal         = ieJoinA firedProbe body'
            in  bodyFinal `seq` go rs (r { irule_body = bodyFinal } : acc) k''
        (rules', n') = go rules [] n
    in  length rules' `seq` (IRules pragmas rules', n')
-- ============================================================
-- Interface methods
-- ============================================================
instrIface :: String -> DefEnv a -> Int -> [IEFace a] -> ([IEFace a], Int)
instrIface modName env n fs =
    trace ("instrIface: got " ++ show (length fs) ++ " interface entries") $
    go n fs
  where
    go n []     = ([], n)
    go n (f:fs) =
        let (f',  n1) = instrFace  modName env n  f
            (fs', n2) = go n1 fs
        in  f' `seq` (f' : fs', n2)
instrFace :: String -> DefEnv a -> Int -> IEFace a -> (IEFace a, Int)
instrFace modName env n f =
    trace ("instrFace: examining " ++ show (ief_name f) ++
           ", ief_body is " ++
           (case ief_body f of
              Nothing -> "Nothing"
              Just _  -> "Just <rules>")) $
    case ief_body f of
        Nothing    -> (f, n)
        Just rules ->
            let fId   = ief_name f
                file  = getRelativeFilePath (getPositionFile (getIdPosition fId))
                label = file ++ ":" ++ modName ++ "_" ++ getIdBaseString fId
                (rules', n') = instrRulesWithLabel env label n rules
            in  (f { ief_body = Just rules' }, n')
-- ============================================================
-- Core walker
-- ============================================================
--
-- inAct = True  : action context  ($display is legal)
--         False : pure value sub-expression  ($display not legal)
--
-- NOTE: this walker (and everything it calls — mkProbeWithCond,
-- renderCond) is NOT rule-specific. instrFace/instrRulesWithLabel
-- route interface-method bodies through this exact same instrExpr
-- entry point that instrRules uses for rule bodies, so any conditional
-- appearing inside a method body gets identical then/else/tern probes
-- and condition rendering, with no special-casing required.
instrExpr :: DefEnv a -> Bool -> String -> Int -> IExpr a -> (IExpr a, Int)
-- ── Action-typed PrimIf (covers if/else-if/else AND case — same IR) ─────
--
-- skipElse RULE (no-undercounting version):
--
-- Skip the outer _else probe ONLY when the else-arm is PrimNoActions —
-- i.e. there is provably no else-content in the source at all, so there
-- is no branch-entry event that could be missed by skipping.
--
-- For every other else-arm shape (bare action-typed PrimIf representing
-- either an else-if chain OR a nested if/if-else block — these are
-- indistinguishable at the IR level after iSplitIf — as well as plain
-- writes/other actions), ALWAYS emit the outer _else probe.
--
-- Rationale: then-arm-shape-based heuristics (skip when then-arm is a
-- leaf, or skip/emit based on "both arms PrimIf") were tried and each
-- has a real counterexample in StressTest.bsv that causes a missed
-- branch-entry event (false negative / under-instrumentation):
--   - "always skip when else-arm is PrimIf"  → under-counts s10/s11/s15
--   - "skip only when then-arm is a leaf"    → under-counts s09
-- Neither rule can be made consistent, because then-arm shape carries
-- no information about what the else-arm actually is.
--
-- This version trades that for guaranteed-safe over-instrumentation:
-- ordinary else-if chains will get a redundant outer _else probe (it
-- fires on a real chain-continuation event, just redundantly with
-- whatever inner probe also eventually fires) — acceptable, since
-- probes firing extra is fine; probes that never fire for a reachable
-- branch is the actual bug.
instrExpr env _inAct label n
    (IAps hd@(ICon _ (ICPrim { primOp = PrimIf }))
          tys@[ty]
          [cond, thenE, elseE])
    | ty == itAction =
        trace (">>> instrExpr: MATCHED action-typed PrimIf at label=" ++ label) $
        let (thenE', n1)    = instrExpr env True label n  thenE
            (elseE', n2)    = instrExpr env True label n1 elseE
            (probeThen, n3) = mkProbeWithCond env (label ++ "_then") (Just cond) n2
            thenFinal       = ieJoinA probeThen thenE'
            -- Pattern match on the ORIGINAL elseE (before instrumentation)
            skipElse        = case elseE of
                                -- Case 1: PrimNoActions — implicit no-else.
                                -- Provably nothing there; safe to skip.
                                ICon _ (ICPrim { primOp = PrimNoActions }) ->
                                    trace ("  [skipElse] PrimNoActions → SKIP else probe") $
                                    True
                                -- Case 2: Everything else (else-if chains,
                                -- nested if/if-else blocks, writes, other
                                -- actions) → ALWAYS emit. Never skip based
                                -- on shape alone; shape cannot reliably
                                -- distinguish a chain from a real nested
                                -- if, and guessing wrong silently drops a
                                -- branch-entry probe.
                                other ->
                                    trace ("  [skipElse] Other (" ++ showConstructor other ++
                                           ") → EMIT else probe") $
                                    False
        in  if skipElse
            then (trace ("  >>> FINAL: SKIP else probe") $
                  IAps hd tys [cond, thenFinal, elseE'], n3)
            else (trace ("  >>> FINAL: EMIT else probe") $
                  let (probeElse, n4) = mkProbeWithCond env (label ++ "_else") (Just cond) n3
                      elseFinal       = ieJoinA probeElse elseE'
                  in  (IAps hd tys [cond, thenFinal, elseFinal], n4))
-- ── PrimJoinActions ─────────────────────────────────────────────────────
instrExpr env inAct label n
    (IAps hd@(ICon _ (ICPrim { primOp = PrimJoinActions })) tys [e1, e2]) =
        trace "instrExpr: MATCHED PrimJoinActions" $
        let (e1', n1) = instrExpr env inAct label n  e1
            (e2', n2) = instrExpr env inAct label n1 e2
        in  (IAps hd tys [e1', e2'], n2)
-- ── PrimNoActions (the empty-action leaf) ───────────────────────────────
-- No probe is added. The enclosing PrimIf's branch-entry probe is sufficient.
instrExpr _env True label n leaf@(ICon _ (ICPrim { primOp = PrimNoActions })) =
    trace "instrExpr: MATCHED PrimNoActions (no probe)" $
    (leaf, n)
-- ── Value-typed PrimIf inside an action context ────────────────────────
instrExpr env True label n
    full@(IAps hd@(ICon _ (ICPrim { primOp = PrimIf }))
               [ty]
               [cond, _thenE, _elseE])
    | ty /= itAction =
        trace "instrExpr: MATCHED value-typed PrimIf in action context" $
        let (probeT, n1) = mkProbeWithCond env (label ++ "_tern_true")  (Just cond) n
            (probeF, n2) = mkProbeWithCond env (label ++ "_tern_false") (Just cond) n1
            guard = IAps hd [itAction] [cond, probeT, probeF]
        in  (ieJoinA guard full, n2)
-- ── Any other action leaf (reg write, foreign call, $display, etc.) ─────
-- Only instrument if a value-typed PrimIf is found inside args (ternary).
instrExpr env True label n e
    | isActionType (iGetType e) =
        case findValuePrimIf e of
            Just _ ->
                trace "instrExpr: MATCHED other action leaf, ternary FOUND" $
                let (mGuard, n') = ternaryGuard env label n e
                in  case mGuard of
                        Just guard -> (ieJoinA guard e, n')
                        Nothing    -> (e, n')
            Nothing ->
                trace "instrExpr: MATCHED other action leaf (no ternary)" $
                (e, n)
-- ── Pure value expression ────────────────────────────────────────────────
instrExpr _env inAct _label n e =
    trace ("instrExpr: UNMATCHED / pure-value fallthrough, inAct=" ++ show inAct) $
    (e, n)
-- ============================================================
-- Ternary-tree instrumentation
-- ============================================================
containsValuePrimIf :: IExpr a -> Bool
containsValuePrimIf e = case unwrapValue e of
    IAps (ICon _ (ICPrim { primOp = PrimIf })) [ty] _
        | ty /= itAction -> True
    IAps _ _ args -> any containsValuePrimIf args
    _ -> False
findValuePrimIf :: IExpr a -> Maybe ()
findValuePrimIf (IAps _ _ args)
    | any containsValuePrimIf args = Just ()
    | otherwise                    = Nothing
findValuePrimIf _ = Nothing
unwrapValue :: IExpr a -> IExpr a
unwrapValue (ICon _ (ICValue { iValDef = e })) = unwrapValue e
unwrapValue e                                  = e
-- | Used by the whas/wget wire-read collapse rule in renderCond.
-- Matches a single-argument application whose head Id has the given
-- base string (e.g. "whas" or "wget"), looking through ICValue
-- wrapping first via unwrapValue so it also matches when the head or
-- the whole application has been wrapped. Returns the single argument
-- if it matches, Nothing otherwise.
matchUnaryNamed :: String -> IExpr a -> Maybe (IExpr a)
matchUnaryNamed name e = case unwrapValue e of
    IAps (ICon hid _) _ [arg]
        | getIdBaseString hid == name -> Just arg
    _ -> Nothing
-- | True if the expression is a genuine don't-care leaf (ICUndet),
-- looking through ICValue wrapping. Used by the whas/wget collapse
-- rule to confirm the else-arm of the ternary is really the compiler's
-- don't-care placeholder and not some other value that merely happens
-- to be unreachable in practice.
isDontCareLeaf :: IExpr a -> Bool
isDontCareLeaf e = case unwrapValue e of
    ICon _ (ICUndet {}) -> True
    _                    -> False
ternaryGuard :: DefEnv a -> String -> Int -> IExpr a -> (Maybe (IExpr a), Int)
ternaryGuard env label n (IAps _ _ args) = goArgs args n
  where
    goArgs []           k = (Nothing, k)
    goArgs (arg : rest) k =
        case findPrimIfDeep arg of
            Just primIf ->
                let (g, k') = buildTree env label primIf k
                in  (Just g, k')
            Nothing -> goArgs rest k
ternaryGuard _env _label n _ = (Nothing, n)
findPrimIfDeep :: IExpr a -> Maybe (IExpr a)
findPrimIfDeep e = case unwrapValue e of
    primIf@(IAps (ICon _ (ICPrim { primOp = PrimIf })) [ty] [_, _, _])
        | ty /= itAction -> Just primIf
    IAps _ _ args -> firstJust (map findPrimIfDeep args)
    _ -> Nothing
  where
    firstJust []           = Nothing
    firstJust (Just x : _) = Just x
    firstJust (Nothing : rest) = firstJust rest
buildTree :: DefEnv a -> String -> IExpr a -> Int -> (IExpr a, Int)
buildTree env label (IAps hd [ty] [cond, thenV, elseV]) n =
    let (thenAction, n1) = buildSide env label "_tern_true"  cond thenV n
        (elseAction, n2) = buildSide env label "_tern_false" cond elseV n1
    in  (IAps hd [itAction] [cond, thenAction, elseAction], n2)
buildTree _env _ e n = (e, n)
buildSide :: DefEnv a -> String -> String -> IExpr a -> IExpr a -> Int -> (IExpr a, Int)
buildSide env label suffix cond v n =
    let (outerProbe, n1) = mkProbeWithCond env (label ++ suffix) (Just cond) n
    in  case unwrapValue v of
            nested@(IAps (ICon _ (ICPrim { primOp = PrimIf })) [ty] [_, _, _])
                | ty /= itAction ->
                    let (innerGuard, n2) = buildTree env (label ++ suffix) nested n1
                    in  (ieJoinA outerProbe innerGuard, n2)
            _ -> (outerProbe, n1)
-- ============================================================
-- Probe builder
-- ============================================================
mkProbe :: DefEnv a -> String -> Int -> (IExpr a, Int)
mkProbe env label n = mkProbeWithCond env label Nothing n
-- | Like mkProbe, but when a condition expression is supplied, its
-- STRUCTURE (not its runtime value) is rendered to text and appended to
-- the probe label, e.g.:
--   $display("file:PROBE_3_RL_s03_..._then (s03 PrimEQ 0)")
-- This is a compile-time description of what the deciding condition WAS
-- in the source, baked directly into the label string. It is NOT a
-- runtime %d read of cond's value — that approach was tried first, but
-- bsc's own Verilog backend constant-folds any condition that's a
-- derived comparison (anything other than a bare register read) down to
-- a literal 1'd1/1'd0 at the call site, since by construction we are
-- already inside the branch that comparison selected. Folding happens
-- downstream of this pass and can't be prevented from here. Printing
-- the condition as static text sidesteps that entirely: nothing is
-- evaluated at simulation time, so nothing can be folded away, and the
-- printed text is always an accurate description of the branch.
--
-- NOTE: an earlier revision of this function also appended a per-
-- condition " @file:line" source-position suffix here, derived by
-- walking the condition down to a register/signal Id and reading its
-- position. That was removed -- see module-header changelog -- because
-- such an Id only ever carries its DECLARATION position in this IR, not
-- the position of the particular use-site/condition being instrumented,
-- which made the suffix actively misleading rather than merely
-- imprecise. The only source-line information in probe labels in this
-- revision is therefore the existing rule-level "_L<n>", which remains
-- reliable since it comes from the rule's own Id.
mkProbeWithCond :: DefEnv a -> String -> Maybe (IExpr a) -> Int -> (IExpr a, Int)
mkProbeWithCond env label mCond n = (probeAction, n + 1)
  where
    probePart :: String
    probePart =
        let (file, colonRest) = break (== ':') label
            rest              = drop 1 colonRest
        in  file ++ ":PROBE_" ++ show n ++ "_" ++ rest
    fmtString :: String
    fmtString = escapePercent rawString
    rawString :: String
    rawString = case mCond of
        Nothing -> probePart
        Just c  -> probePart ++ " " ++ renderCond env c
    -- Verilog's $display treats '%' as the start of a format
    -- specifier. renderCond/prettyOp can legitimately emit a literal
    -- '%' character (e.g. PrimRem renders as "%" for "x % y" style
    -- conditions), and that text is spliced directly into the
    -- $display format string below. Left unescaped, a condition like
    -- "(rg_inst_count % 10000000)" produces an invalid format code
    -- ("% ") and Verilator/Verilog rejects the generated file outright.
    -- Doubling every literal '%' to '%%' here — at the single
    -- chokepoint where the format string is finalized — makes it print
    -- as a literal percent sign at simulation time without touching
    -- renderCond/prettyOp, which should keep producing clean,
    -- human-readable '%' text for any other consumer.
    escapePercent :: String -> String
    escapePercent = concatMap (\c -> if c == '%' then "%%" else [c])
    displayType :: IType
    displayType = itString `itFun` itAction
    displayCon :: IExpr a
    displayCon =
        ICon idDisplay
             (ICForeign { iConType = displayType
                        , fName    = "$display"
                        , isC      = False
                        , foports  = Nothing
                        , fcallNo  = Just (toInteger n)
                        })
    probeAction :: IExpr a
    probeAction = IAps displayCon [] [iMkString fmtString]
-- ============================================================
-- Condition rendering
-- ============================================================
--
-- | Maps PrimOp constructor names (from `show`, confirmed plain derived
-- Show with no custom override — Prim.hs: deriving (Eq, Ord, Show, ...))
-- to readable infix/prefix symbols for the condition-text labels. Works
-- on the STRING `show` produces rather than importing/pattern-matching
-- every PrimOp constructor by name, so this can't fail to build even if
-- this bsc tree's PrimOp list differs slightly from the one below — any
-- constructor not covered here just falls through to its raw name
-- unchanged (the `other -> other` case), same as before this change.
prettyOp :: String -> String
prettyOp "PrimAdd"  = "+"
prettyOp "PrimSub"  = "-"
prettyOp "PrimMul"  = "*"
prettyOp "PrimQuot" = "/"
prettyOp "PrimRem"  = "%"
prettyOp "PrimAnd"  = "&&"
prettyOp "PrimOr"   = "||"
prettyOp "PrimXor"  = "^"
prettyOp "PrimInv"  = "!"
prettyOp "PrimNeg"  = "-"      -- unary
prettyOp "PrimEQ"   = "=="
prettyOp "PrimULE"  = "<="
prettyOp "PrimULT"  = "<"
prettyOp "PrimSLE"  = "<="
prettyOp "PrimSLT"  = "<"
prettyOp "PrimSL"   = "<<"
prettyOp "PrimSRL"  = ">>"
prettyOp "PrimSRA"  = ">>>"
prettyOp "PrimBNot" = "~"
prettyOp "PrimBAnd" = "&"
prettyOp "PrimBOr"  = "|"
prettyOp other      = other
-- | Render a condition expression's STRUCTURE as readable text, e.g.
-- "(s03 PrimEQ 0)" or "(sel)". Deliberately avoids importing/naming
-- specific PrimOp constructors (PrimEQ, PrimLT, etc.) since their exact
-- names in this bsc tree aren't being assumed here; `show` on the
-- PrimOp value itself recovers its real constructor name generically
-- and safely, without risking a "no such constructor" build failure.
-- Falls back to a generic placeholder for any IExpr shape not covered
-- (e.g. let-bindings, lambdas) rather than guessing.
--
-- IVar case: an IVar surviving to this pass is a reference into
-- imod_local_defs, not a locally-bound name (see DefEnv comment above).
-- Look it up in `env` and recurse into its actual definition so e.g.
-- "b__h908" renders as the real "(s03 PrimEQ 0)" it was bound to,
-- instead of the synthesized intermediate name. The looked-up id is
-- removed from the env before recursing as a defensive guard against
-- a pathological self-referential def causing non-termination — real
-- hardware IR shouldn't ever have one, but this keeps the pass total
-- regardless. Falls back to the bare name if not found in env (e.g.
-- state-element ports, method arguments — these are legitimately not
-- in imod_local_defs and the bare name IS the correct thing to print).
--
-- Lookup is by Id IDENTITY (`k == vid`), not base-string equality —
-- see module-header changelog for why the string-based version was a
-- real correctness bug, not just a style choice.
renderCond :: DefEnv a -> IExpr a -> String
renderCond env (IVar vid) =
    case [ e | (k, e) <- env, k == vid ] of
        (rhs : _) ->
            renderCond [ kv | kv@(k, _) <- env, k /= vid ] rhs
        [] -> getIdBaseString vid
renderCond _env (ICon _ (ICPrim { primOp = op })) = prettyOp (show op)
-- Wire-read collapse -- MUST come before the generic ternary-rendering
-- case directly below, since this is a special case of that same
-- PrimIf shape and needs first refusal on it.
--
-- A Wire/DWire only holds a value on the cycle it's written, so every
-- read of one compiles in the IR to: "if it was driven this cycle
-- (whas X), use its value (wget X), else don't-care (_)". This is
-- real, accurate compiler-generated structure -- not a display/probe
-- artifact -- but it carries no decision-relevant information for a
-- human reading a condition: by construction we are always inside the
-- branch that already selected this value, so the don't-care arm is
-- never actually live. Faithfully expanding it (as the generic ternary
-- case below would) produces three nested fragments referencing the
-- same wire for every single wire read in a condition, which is the
-- single biggest source of unreadable bloat in complex conditions
-- (e.g. stage3.bsv's branch-misprediction logic, which reads several
-- such wires multiple times each). Collapse the whole "(whas X) ?
-- (wget X) : _" shape down to plain "X" instead.
--
-- Matching is structural-shape based (head Id is named "whas"/"wget",
-- single argument, else-arm is a genuine don't-care) plus a textual
-- equality check between the whas- and wget- argument (comparing their
-- *rendered* text rather than requiring an Eq IExpr instance, since
-- none is assumed to exist). This intentionally only collapses the
-- exact "same wire on both sides" shape; anything that doesn't match
-- falls through unchanged to the generic ternary case below, so this
-- can never silently drop information for shapes it doesn't recognize.
renderCond env (IAps (ICon _ (ICPrim { primOp = PrimIf })) _ [cond, thenV, elseV])
    | Just wArg <- matchUnaryNamed "whas" cond
    , Just gArg <- matchUnaryNamed "wget" thenV
    , isDontCareLeaf elseV
    , renderCond env wArg == renderCond env gArg
    = renderCond env wArg
-- Ternary (value-typed PrimIf) rendering -- MUST come before the
-- generic "IAps (ICon _ (ICPrim ...)) _ args" case below, since that
-- generic case would otherwise catch a 3-arg PrimIf application first
-- and print it as the literal infix "(cond PrimIf thenV PrimIf elseV)"
-- (prettyOp has no entry for "PrimIf", so it falls through to "other ->
-- other" unchanged, then gets spliced in as a bare infix operator --
-- same class of bug as the unescaped '%' from PrimRem, just for a
-- ternary instead of a mod operator). This happens whenever a condition
-- itself contains a nested ternary (e.g. a PrimIf-typed value feeding
-- into a comparison), which renderCond recurses into via the generic
-- IAps case without this dedicated pattern. Render it as a proper
-- "cond ? thenV : elseV" ternary instead.
renderCond env (IAps (ICon _ (ICPrim { primOp = PrimIf })) _ [cond, thenV, elseV]) =
    "(" ++ renderCond env cond ++ " ? " ++
           renderCond env thenV ++ " : " ++
           renderCond env elseV ++ ")"
-- Numeric integer literal — confirmed constructor/field from ISyntax.hs:
--   ICInt { iConType :: IType, iVal :: IntLit }
-- This is the actual fix for the "(s03 PrimEQ _)" bug: literal constants
-- (the "0" in s03==0) were falling through to the generic ICon case
-- below, which only has access to the Id (which carries no value for a
-- synthesized literal), never the literal's real numeric payload.
--
-- KNOWN LIMITATION (unresolved, flagged separately from the position
-- work in this revision): this pass runs before sizing/iLift, so an
-- unsized '1 (all-ones) literal shows up here as a giant pre-sizing
-- integer (e.g. 9223372036854775807) rather than as the actual N-bit
-- hardware constant. `show v` is therefore not always a faithful
-- transcription of the final RTL value for such literals. Left as-is
-- for this revision; candidate fix is special-casing maxBound-shaped
-- values to print as "<all-ones>" or deferring instrumentation until
-- after sizing is resolved.
renderCond _env (ICon _ (ICInt { iVal = v })) = show v
renderCond _env (ICon _ (ICString { iStr = s })) = show s
renderCond _env (ICon _ (ICChar { iChar = c })) = show c
renderCond _env (ICon _ (ICUndet {})) = "_"  -- genuinely a don't-care; "_" is correct here
-- ICValue: this is the actual mechanism behind the "b__hNNNN" names,
-- not imod_local_defs. ICValue wraps an Id TOGETHER with its own
-- inline definition (iValDef) — the same constructor `unwrapValue`
-- above already exists to peel off for findValuePrimIf/buildSide, so
-- renderCond (and other consumers of DefEnv) recurse into the real
-- expression it wraps instead of printing the wrapper Id's bare name.
renderCond env (ICon _ (ICValue { iValDef = e })) = renderCond env e
renderCond _env (ICon cid _) =
    -- For ordinary named identifiers, getIdBaseString gives the real
    -- name. For any other compiler-synthesized constant not covered by
    -- the specific cases above, fall back to showing the Id itself.
    let nm = getIdBaseString cid
    in  if nm == "_" || null nm then show cid else nm
renderCond env (IAps (ICon _ (ICPrim { primOp = op })) _ args) =
    "(" ++ intercalate (" " ++ prettyOp (show op) ++ " ") (map (renderCond env) args) ++ ")"
-- Method-call prettifier: a bare register/wire read like "s03._read()"
-- shows up here as "(s03 _read)" via the generic case below — strip the
-- redundant "_read" head for the common single-arg accessor pattern so
-- it renders as plain "s03" instead. Anything else (multi-arg methods,
-- non-_read methods) falls through to the generic rendering unchanged.
renderCond env (IAps (ICon hid _) _ [arg])
    | getIdBaseString hid == "read" = renderCond env arg
renderCond env (IAps hd _ args) =
    "(" ++ renderCond env hd ++ concatMap ((' ':) . renderCond env) args ++ ")"
renderCond _env _ = "<expr>"
-- ============================================================
-- Helper function for diagnostic output
-- ============================================================
showConstructor :: IExpr a -> String
showConstructor (ILam {})       = "ILam"
showConstructor (IAps {})       = "IAps"
showConstructor (IVar {})       = "IVar"
showConstructor (ILAM {})       = "ILAM"
showConstructor (ICon {})       = "ICon"
showConstructor (IRefT {})      = "IRefT"
showConstructor _               = "Unknown"
-- ============================================================
-- bsc.hs patch  (unified diff, apply with  patch -p1)
-- ============================================================
--
-- --- a/src/comp/bsc.hs
-- +++ b/src/comp/bsc.hs
-- @@ import ISyntaxUtil ...
-- +import ICoverage(iInstrumentCoverage)
--
-- @@ -736,6 +737,11 @@
--      t <- dump errh flags t DFsplitIf dumpnames imod_splitif
--      stats flags DFsplitIf imod_splitif
--
-- +    -- Branch-coverage instrumentation
-- +    let imod_cov = iInstrumentCoverage imod_splitif
-- +
--      -- Lift where possible
--      start flags DFlift
-- -    let imod_lift = iLift errh flags imod_splitif
-- +    let imod_lift = iLift errh flags imod_cov
