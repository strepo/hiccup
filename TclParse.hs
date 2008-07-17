{-# LANGUAGE BangPatterns,OverloadedStrings #-}

module TclParse ( TclWord(..)
                 ,runParse 
                 ,parseList 
                 ,doVarParse
                 ,parseSub
                 ,TokCmd
                 ,SubCmd
                 ,parseSubst
                 ,escapeChar
                 ,Subst(..)
                 ,tclParseTests
                )  where
 

import BSParse
import Util 
import qualified Data.ByteString.Char8 as B
import Test.HUnit


data TclWord = Word !B.ByteString 
             | Subcommand SubCmd
             | NoSub !B.ByteString (Result [TokCmd])
             | Expand TclWord deriving (Show,Eq)

type TokCmd = (TclWord, [TclWord])
type SubCmd = [TokCmd]


runParse :: Parser [TokCmd]
runParse = parseStatements `wrapWith` asCmds
 where asCmds lst = [ let (c:a) = x in (c,a) | x <- lst, not (null x)]


parseStatements :: Parser [[TclWord]]
parseStatements = multi1 (eatSpaces .>> parseStatement) `pass` parseEof
  

parseStatement :: Parser [TclWord]
parseStatement = choose [eatAndNext, parseEof, parseTokens]
 where stmtSep = parseOneOf "\n;" .>> eatSpaces 
       eatAndNext = (stmtSep `orElse` parseComment) .>> parseStatement

parseComment = pchar '#' .>> parseMany (ignored `orElse` (eat escapedChar)) .>> eatSpaces
 where ignored = eat (getPred1 (`notElem` "\n\\") "not newline or slash")
       eat p = p .>> emit ()

parseTokens :: Parser [TclWord]
parseTokens = parseMany1 (eatSpaces .>> parseToken)

parseToken :: Parser TclWord
parseToken str = do 
   h <- safeHead "token" str
   case h of
     '{'  -> (parseExpand `orElse` parseNoSub) str
     '['  -> (parseSub `wrapWith` Subcommand) str
     '"'  -> (parseRichStr `wrapWith` Word) str
     '\\' -> handleEsc str
     _    -> (wordToken `wrapWith` Word) str
 where parseNoSub = parseBlock `wrapWith` mkNoSub
       parseExpand = parseLit "{*}" .>> (parseToken `wrapWith` Expand)

mkNoSub s = NoSub s (runParse s)

parseRichStr = pchar '"' .>> (inside `wrapWith` B.concat) `pass` (pchar '"')
 where noquotes = getPred1 (`notElem` "\"\\[$") "non-quote chars"
       inside = parseMany $ choose [noquotes, escapedChar, consumed parseSub, inner_var]
       inner_var = consumed (doVarParse `orElse` pchar '$')

(.>>=) pa f s = do
  (v,r) <- pa s
  v2 <- f v 
  return (v2,r)

parseSub :: Parser SubCmd
parseSub = brackets $ (parseTokens .>>= unconsc) `sepBy1` (eatSpaces .>> pchar ';')
 where unconsc p = case p of
            [] -> fail "empty subcommand"
            (ph:pt) -> return (ph,pt)

handleEsc :: Parser TclWord
handleEsc = line_continue `orElse` esc_word
 where line_continue = parseLit "\\\n" .>> eatSpaces .>> parseToken
       esc_word = (chain [escapedChar, tryGet wordToken]) `wrapWith` Word

-- List parsing
parseList s = parseList_ s >>= return . fst
parseList_ :: Parser [BString]
parseList_ = eatWhite .>> (parseEof `orElse` multi1 plistItem)
 where isWhite = (`elem` " \t\n")
       eatWhite st = return ((), B.dropWhile isWhite st)
       plistItem = listDisp `pass` eatWhite

listDisp str = do h <- safeHead "list item" str
                  case h of
                   '{' -> parseBlock str
                   '"' -> parseStr str 
                   _   -> getListItem str

getListItem s = if B.null w then fail "can't parse list item" else return (w,n)
 where (w,n) = B.splitAt (listItemEnd s) s

listItemEnd s = inner 0 False where 
   isTerminal = (`B.elem` "{}\" \t\n")
   inner i esc = if i == B.length s then i
                     else if esc then inner (i+1) False
                           else case B.index s i of
                                  '\\' -> inner (i+1) True
                                  v  -> if isTerminal v then i else inner (i+1) False


-- TODO: Is SEsc really useful? Escaped chars are probably always handled
-- the same way, and could be done here.
data Subst = SStr !BString | SEsc !Char | 
             SVar !BString | SCmd SubCmd deriving (Eq,Show)

parseSubst :: (Bool,Bool,Bool) -> Parser [Subst]
parseSubst (vars,esc,cmds) = inner `wrapWith` sconcat
 where no_special = getPred1 (`notElem` "\\[$") "non-special chars"
       inner = parseMany (choose [st no_special, 
                                  may vars SVar doVarParse,
                                  may cmds SCmd parseSub,
                                  tryEsc,
                                  st parseAny])
       st x = x `wrapWith` SStr
       may b c f = if b then f `wrapWith` c else st (consumed f)
       tryEsc = if esc then (escChar `wrapWith` SEsc) else (\_ -> fail "no esc") 
       escChar = pchar '\\' .>> (parseAny `wrapWith` B.head)
       sconcat [] = []
       sconcat (SStr s:xs) = let (sl,r) = spanStrs xs []
                             in SStr (B.concat (s:sl)) : sconcat r 
       sconcat (t:xs) = t : sconcat xs
       spanStrs (SStr x:xs) a = spanStrs xs (x:a)
       spanStrs rst a = (reverse a,rst)
       sreduce lst = case lst of
               []                 -> []
               (SStr x:SStr y:xs) -> sreduce ((SStr (B.append x y)):xs)
               (x:xs) -> x : sreduce xs

doVarParse :: Parser BString
doVarParse = pchar '$' .>> parseVarRef

parseVarRef :: Parser BString
parseVarRef = chain [ initial 
                      ,tryGet getNS
                      ,tryGet parseInd ]
 where getNS = chain [sep, parseVarTerm, tryGet getNS]
       initial = chain [tryGet sep, parseVarTerm]
       sep = parseLit "::"

parseVarTerm :: Parser BString
parseVarTerm = getVar `orElse` braceVar
 where getVar = getPred1 wordChar "word"

parseInd :: Parser BString
parseInd = chain [pchar '(', getPred (/= ')'), pchar ')']

wordToken = consumed (parseMany1 (someVar `orElse` inner `orElse` someCmd))
 where simple = getPred1 (`notElem` " $[]\n\t;\\") "inner word"
       inner = consumed (parseMany1 (simple `orElse` escapedChar)) 
       someVar = chain_ [pchar '$', parseVarBody, tryGet parseInd]
       someCmd = consumed parseSub

parseVarBody = (braceVar `wrapWith` braceIt) `orElse` no_special
 where braceIt w = B.concat ["{", w , "}"]
       no_special = getPred1 (`notElem` "( ${}[]\n\t;") "inner word"

{-# INLINE escapeChar #-}
escapeChar c = case c of
          'n' -> '\n'
          't' -> '\t'
          'a' -> '\a'
          _  -> c


tclParseTests = TestList [ runParseTests, 
                           parseVarRefTests,
                           parseListTests,
                           parseTokensTests,
                           wordTokenTests, 
                           parseRichStrTests,
                           commentTests,
                           parseSubstTests]

commentTests = "parseComment" ~: TestList [
   "# hey there" `should_be` ""
   ,"# hey there \n FISH" `should_be` "\n FISH"
   ,"# hey there \\\n FISH" `should_be` ""
 ]
  where should_be str res = (B.unpack str) ~: Right ((),res) ~=? parseComment str

runParseTests = "runParse" ~: TestList [
     "one token" ~: (pr ["exit"]) ?=? "exit",
     "multi-line" ~: (pr ["puts", "44"]) ?=? " puts \\\n   44",
     "escaped space" ~: (pr ["puts", "\\ "]) ?=? " puts \\ ",
     "empty" ~: ([],"") ?=? " ",
     "empty2" ~: ([],"") ?=? "",
     "unmatched" ~: "{ { }" `should_fail` (),
     "a b " ~: "a b " `should_be` ["a", "b"],
     "two vars" ~: (pr ["puts", "$one$two"]) ?=? "puts $one$two",
     "brace inside" ~: (pr ["puts", "x{$a}x"]) ?=? "puts x{$a}x",
     "brace" ~: (pr ["puts", "${oh no}"]) ?=? "puts ${oh no}",
     "arr 1" ~: (pr ["set","buggy(4)", "11"]) ?=? "set buggy(4) 11",
     "arr 2" ~: (pr ["set","buggy($bean)", "11"]) ?=? "set buggy($bean) 11",
     "arr 3" ~: (pr ["set","buggy($bean)", "$koo"]) ?=? "set buggy($bean) $koo"
     ,"arr 4" ~: (pr ["set","buggy($bean)", "${wow}"]) ?=? "set buggy($bean) ${wow}"
     ,"arr w/ esc index" ~: (pr ["set","x(\\))", "4"]) ?=? "set x(\\)) 4"
     ,"quoted ws arr" ~: (pr ["set","arr(1 2)", "4"]) ?=? "set \"arr(1 2)\" 4"
     ,"hashed num" ~: (pr ["uplevel", "#1", "exit"]) ?=? "uplevel #1 exit"
     ,"command appended" ~: (pr ["set", "val", "x[nop 4]"]) ?=? "set val x[nop 4]"
     ,"unquoted ws arr" ~: (pr ["puts","$arr(1 2)"]) ?=? "puts $arr(1 2)"
     ,"expand" ~: ([(Word "incr", [Expand (Word "$boo")])], "") ?=? "incr {*}$boo"
     ,"no expand" ~: ([(Word "incr", [mkNoSub "*", Word "$boo"])], "") ?=? "incr {*} $boo"
  ]
 where should_fail str () = (runParse str) `should_fail_` ()
       should_be str res = Right (pr res) ~=? (runParse str)
       (?=?) (res,r) str = Right (res, r) ~=? runParse str
       pr (x:xs) = ([(Word x, map Word xs)], "")
       pr []     = error "bad test!"

wordTokenTests = "wordToken" ~: TestList [
     "empty" ~: "" `should_fail` ()
     ,"Simple2" ~: ("$whoa", "") ?=? "$whoa"
     ,"Simple with bang" ~: ("whoa!", " ") ?=? "whoa! "
     ,"braced, then normal" ~: valid_word "${x}$x"
     ,"normal, then cmd" ~: ("fish[nop 5]", "") ?=? "fish[nop 5]"
     ,"non-var, then var" ~: ("**$x", "") ?=? "**$x"
     ,"non-var, then var w/ space" ~: valid_word "**${a b}"
     ,"escaped" ~: valid_word "x\\ y"
     ,"inner bracket" ~: valid_word "a{{" 
     ,"inner bracket 2" ~: valid_word "a}|" 
  ]
 where should_fail str _ = (wordToken str) `should_fail_` ()
       (?=?) res str = Right res ~=? wordToken str
       should_be str res = Right res ~=? wordToken str
       valid_word x = x `should_be` (x,"")

parseVarRefTests = "parseVarRef" ~: TestList [
     "empty string" ~: "" `should_fail` ()
    ,"standard" ~: "boo" ?=> ("boo", "")
    ,"global" ~: "::boo" ?=> ("::boo", "")
    ,"arr1" ~: "boo(one) " ?=> ("boo(one)", " ")
    ,"ns arr1" ~: "::big::boo(one) " ?=> ("::big::boo(one)", " ")
    ,"::big(3)$::boo(one)" ?=> ("::big(3)", "$::boo(one)")
    , "triple" ~: "::one::two::three" ?=> ("::one::two::three","")
    , "brace" ~: "::one::{t o}::three" ?=> ("::one::t o::three","")
    , "mid paren" ~: "::one::two(1)::three" ?=> ("::one::two(1)", "::three")
    , "\\( in index" ~: "x(\\()" ?=> ("x(\\()", "")
   ]
 where (?=>) str (p,r) = Right (p, r) ~=? parseVarRef str
       should_fail a () = (parseVarRef a) `should_fail_` ()

parseListTests = "parseList" ~: TestList [
     " x " `should_be` ["x"]
     ,""   `should_be` []
     ,"\t \t" `should_be` []
     ," x y " `should_be` ["x", "y"]
     ,"x y" ~: "x y" ?=> ["x", "y"]
     ,"x { y {z}}" `should_be` ["x", " y {z}"]
     ,"x { y 0 }" ~: "x { y 0 }" ?=> ["x", " y 0 "]
     ,"x [puts yay]" ~: "x [puts yay]" ?=> ["x", "[puts", "yay]"]
     ," y { \\{ \\{ \\{ } { x }" `should_be` ["y", " \\{ \\{ \\{ ", " x "]
     , "unmatched fail" ~: fails " { { "
     ,"x {y 0}" ~: "x {y 0}" ?=> ["x", "y 0"]
     ,"with nl" ~: "x  1 \n y 2 \n z 3" ?=> ["x", "1", "y", "2", "z", "3"]
     ,"escaped1" ~: "x \\{ z" ?=> ["x", "\\{", "z"]
   ]
 where (?=>) str res = Right res ~=? parseList str
       fails str = (parseList str) `should_fail_` ()
       should_be str res = (B.unpack str) ~: Right res ~=? parseList str

parseRichStrTests = "parseRichStr" ~: TestList [
       full_parse ""
      ,full_parse "\\\""
      ,full_parse "how [list \"are\"] you?"
      ,full_parse "eat [list {\"}]"
      ,full_parse "say ${\"}"
      ,full_parse "dolla $ bill"
   ]
  where should_be str res = (B.unpack str) ~: Right res ~=? parseRichStr str
        full_parse str = (B.concat ["\"", str, "\""]) `should_be` (str,"")

parseTokensTests = "parseTokens" ~: TestList [
     " x " ~: "x" ?=> ([Word "x"], "")
     ," x y " ~: " x y " ?=> ([Word "x", Word "y"], " ")
     ,"x y" ~: "x y" ?=> ([Word "x", Word "y"], "")
     ,"x { y 0 }" ~: "x { y 0 }" ?=> ([Word "x", nosub " y 0 "], "")
     ,"x {y 0}" ~: "x {y 0}" ?=> ([Word "x", nosub "y 0"], "")
   ]
 where (?=>) str (res,r) = Right (res, r) ~=? parseTokens str
       nosub = mkNoSub

parseSubstTests = "parseSubst" ~: TestList [
    (all_on, "A cat") `should_be` [SStr "A cat"]
    ,(all_on, "A $cat") `should_be` [SStr "A ", SVar "cat"]
    ,(no_var, "A $cat") `should_be` [SStr "A $cat"]
    ,(all_on, "A \\cat") `should_be` [SStr "A ", SEsc 'c', SStr "at"]
    ,(no_esc, "A \\cat") `should_be` [SStr "A \\cat"]
    ,(all_on, "\\[fish]") `should_be` [SEsc '[', SStr "fish]"]
    ,(all_on, "[fish face") `should_be` [SStr "[fish face"]
    ,(no_esc, "One \\n Two") `should_be` [SStr "One \\n Two"]
    ,(no_esc, " \\$fish ") `should_be` [SStr " \\", SVar "fish", SStr " "]
  ]
 where should_be (opt, str) res = (B.unpack str) ~: Right (res,"") ~=? parseSubst opt str
       all_on = (True,True,True)
       no_esc = (True,False,True)
       no_var = (False,True,True)