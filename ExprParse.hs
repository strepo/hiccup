module ExprParse (exprParseTests, riExpr, exprCompile) where
import Text.ParserCombinators.Parsec
import Text.ParserCombinators.Parsec.Language
import qualified Text.ParserCombinators.Parsec.Token as P
import Text.ParserCombinators.Parsec.Expr
import qualified TclLib.MathProcs as Math
import Test.HUnit

import qualified TclObj as T
import qualified Data.Map as M

import Util

lexer :: P.TokenParser ()
lexer = P.makeTokenParser emptyDef

intOrFloat = P.naturalOrFloat lexer
symbol  = P.symbol lexer
schar c = char c >> P.whiteSpace lexer
identifier  = P.identifier lexer
stringLit = P.stringLiteral lexer

data Op = OpDiv | OpPlus | OpMinus | OpTimes | OpEql | OpNeql |
          OpLt | OpGt | OpLte | OpGte | OpStrNe | OpStrEq | OpAnd |
	  OpOr
  deriving (Show,Eq)

data TExp = TOp !Op TExp TExp | TVar String | TFun String TExp | TVal T.TclObj deriving (Show,Eq)

exprCompile :: (Monad m) => String -> m ((BString -> m T.TclObj) -> m T.TclObj)
exprCompile s = do v <- expr s
                   return $ runExpr v


expr s = case parse pexpr "" s of
           Left err -> fail $ "Bad parse: (" ++ s ++ "): " ++ show err
           Right res -> return res

instance Num TExp where
  a + b = TOp OpPlus a b
  (-) = TOp OpMinus
  (*) = TOp OpTimes
  abs = undefined
  signum = undefined
  negate = undefined
  fromInteger i =  TVal (T.mkTclInt (fromIntegral i))

(.&&) = TOp OpAnd
(.||) = TOp OpOr

(.<) = TOp OpLt
(.<=) = TOp OpLte
(.>) = TOp OpGt
(.>=) = TOp OpGte
(.==) = TOp OpEql

eq = TOp OpStrEq
ne = TOp OpStrNe

objapply :: (Monad m) => (BString -> m T.TclObj) -> (T.TclObj -> T.TclObj -> m T.TclObj) -> TExp -> TExp -> m T.TclObj
objapply lu f x y = do
  i1 <- runExpr x lu 
  i2 <- runExpr y lu
  f i1 i2

funapply lu f x = do
  d <- runExpr x lu >>= T.asDouble
  return . T.mkTclDouble $ (f d) 

runExpr :: (Monad m) => TExp -> (BString -> m T.TclObj) -> m T.TclObj
runExpr exp lu = 
  case exp of
    (TOp OpPlus a b) -> objap Math.plus a b
    (TOp OpTimes a b) -> objap (procMath (*)) a b
    (TOp OpMinus a b) -> objap (procMath (-)) a b
    (TOp OpDiv a b) -> objap nop a b
    (TOp OpEql a b) -> objap (procCmp (==)) a b
    (TOp OpNeql a b) -> objap (procCmp (/=)) a b
    (TOp OpLt a b) -> objap (procCmp (<)) a b
    (TOp OpGt a b) -> objap (procCmp (>)) a b
    (TOp OpLte a b) -> objap (procCmp (<=)) a b
    (TOp OpGte a b) -> objap (procCmp (>=)) a b
    (TOp OpStrEq a b) -> objap (procStr (==)) a b
    (TOp OpStrNe a b) -> objap (procStr (/=)) a b
    (TOp OpAnd a b) -> objap (procBool (&&)) a b
    (TOp OpOr a b) -> objap (procBool (||)) a b
    (TVal v) -> return $! v
    (TVar n) -> lu (pack n)
    (TFun "sin" v)  -> funapply lu sin v
    (TFun "cos" v)  -> funapply lu cos v
    (TFun "sqrt" v) -> funapply lu sqrt v
    (TFun "rand" v) -> lu (pack "rand") -- TODO: Check args
    _               -> fail $ "expr can't currently eval: " ++ (show exp)
 where nop _ = fail "sorry, not implemented"
       objap = objapply lu


procMath f a b =   do ai <- T.asInt a
                      bi <- T.asInt b
                      return $! T.mkTclInt (ai `f` bi)
procCmp f  a b   = do ai <- T.asInt a
                      bi <- T.asInt b
                      return $! T.fromBool (ai `f` bi)
procBool f a b = do 
   let ab = T.asBool a
   let bb = T.asBool b
   return $! T.fromBool (ab `f` bb)
procStr f  a b   = return $! T.fromBool ((T.asBStr a) `f` (T.asBStr b))

pexpr :: Parser TExp
pexpr   = many space >> buildExpressionParser table factor

table = [[op1 '*' (OpTimes) AssocLeft, op1 '/' (OpDiv)  AssocLeft]
        ,[op1 '+' (OpPlus) AssocLeft, op1 '-' (OpMinus) AssocLeft] 
        ,[op "==" (OpEql) AssocLeft, op "!=" (OpNeql) AssocLeft] 
        ,[op "eq" OpStrEq AssocLeft, op "ne" OpStrNe AssocLeft]
        ,[tryop "<=" (OpLte) AssocLeft, tryop ">=" (OpGte) AssocLeft] 
        ,[op1 '<' OpLt AssocLeft, op1 '>' OpGt AssocLeft]
	,[op "&&" OpAnd AssocLeft, op "||" OpOr AssocLeft]
     ]
   where
     op s f assoc = Infix (do{ symbol s; return (TOp f)}) assoc
     op1 s f assoc = Infix (do{ schar s; return (TOp f)}) assoc
     tryop s f assoc = Infix (do{ try(symbol s); return (TOp f)}) assoc

factor = do schar '('
            x <- pexpr
            schar ')'
            return x
         <|> numval <|> boolval <|> mystr <|> myvar <|> myfun  <?> "term"
            
numval = do iorf <- intOrFloat 
            return $ case iorf of
                      Left  i -> tInt (fromIntegral i)
                      Right f -> tFloat f
mystr = do s <- stringLit
           return $ tStr s
        <?> "string"

boolval = do
  b <- ((s "true" <|> try (s "on")) >> return True) 
       <|> ((s "false" <|> s "off") >> return False)
  return . TVal $ T.fromBool b
 where s str = symbol str

myvar = do char '$' 
           s <- identifier
           return $ TVar s
        <?> "variable"

myfun = do s <- identifier
           char '('
           inner <- pexpr <|> (symbol "" >> return (tStr "")) 
           char ')'
           return $ TFun s inner


--- Unit Testing ---

ptest a (p,s) = a ~=? (tparse p s)
 where tparse p s = case parse p "" s of
                      Left _    -> Nothing
                      Right res -> Just res

a ?=? x = ptest (Just a) x
isBad x = ptest Nothing x

aNumberTests = TestList
     ["ANumber1" ~: (tInt 3) ?=? (numval, "3"),
      "double" ~: (tFloat 1.25) ?=? (numval, "1.25"),
      --"ANumber2" ~: (tInt (-1)) ?=? (myint, "-1"),
      "ANumber3" ~: isBad (numval, "Button")]

stringTests = TestList [
    "string1" ~: (tStr "boo") ?=? (mystr, "\"boo\"") 
    ,"string2" ~: (tStr "") ?=? (mystr, "\"\"") 
    ,"string3" ~: (tStr "44") ?=? (mystr, "\"44\"") 
 ]

varTests = TestList [
    "var1" ~: (TVar "boo") ??= "$boo" 
    ,"var2" ~: (TVar "keebler") ??= "$keebler" 
    ,"var3" ~: bad "$" 
  ]
 where bad v = ptest Nothing (myvar,v)
       a ??= v = ptest (Just a) (myvar,v)
 
tInt i = TVal (T.mkTclInt i)
tStr s = TVal (T.mkTclStr s)
tFloat f = TVal (T.mkTclStr (show f))

exprTests = TestList 
    [ "expr1" ~: (tInt 3) ?=? (pexpr, "3")
     ,"expr2" ~: ((tInt 3) + (tInt 1)) ?=? (pexpr, "3+1")
     ,"var+var" ~: ((TVar "a") + (TVar "b")) ?=? (pexpr, "$a+$b")
     ,"expr2 in paren" ~: ((tInt 3) + (tInt 1)) ?=? (pexpr, "(3+1)")
     ,"expr2 in paren 2" ~: ((tInt 3) + (tInt 1)) ?=? (pexpr, "((3)+1)")
     ,"expr3" ~: ((tInt 2) + (tInt 5) * (tInt 5)) ?=? (pexpr, "2+5*5")
     ,"lt" ~: ((tInt 2) .< (tInt 5)) ?=? (pexpr, "2 < 5")
     ,"lte" ~: ((tInt 2) .<= (tInt 5)) ?=? (pexpr, "2 <= 5")
     ,"gt" ~: ((tInt 5) .> (tInt 5)) ?=? (pexpr, "5 > 5")
     ,"gte" ~: ((tInt 6) .>= (tInt 5)) ?=? (pexpr, "6 >= 5")
     ,"string eq" ~: ((tStr "X") `eq` (tStr "Y")) ?=? (pexpr, "\"X\" eq \"Y\"")
     ,"string eq var" ~: ((TVar "X") `eq` (tStr "Y")) ?=? (pexpr, "$X eq \"Y\"")
     ,"string ne" ~: ((tStr "X") `ne` (tStr "Y")) ?=? (pexpr, " \"X\" ne \"Y\"")
     ,"varstorm1" ~: (((TVar "me") + (TVar "hey")) .< (TVar "something")) ?=? (pexpr, "($me + $hey) < $something")
     ,"varstorm2" ~: (((TVar "me") + (TVar "hey")) .< (TVar "something")) ?=? (pexpr, "($me + $hey)< $something")
     ,"varstorm3" ~: (((TVar "me") + (TVar "hey")) .< (TVar "st")) ?=? (pexpr, " ( $me+$hey ) <$st ")
     ,"varstorm4" ~: (((TVar "me") * (TVar "hey")) .== (TVar "st")) ?=? (pexpr, " $me * $hey  == $st ")
     ,"fun1" ~: (TFun "sin" (tInt 44)) ?=? (pexpr, "sin(44)")
     ,"fun2" ~: ((tInt 11) + (TFun "sin" (tInt 44))) ?=? (pexpr, "11 + sin(44)")
     ,"fun3" ~: (TFun "rand" (tStr "")) ?=? (pexpr, "rand()")
     ,"and expr" ~: ((tInt 1) .&& (tInt 2)) ?=? (pexpr, "1 && 2")
     ,"or expr" ~: (((tInt 1) + (tInt 1)) .|| (tInt 2)) ?=? (pexpr, "(1+1) || 2")
 ]

mint v = T.mkTclInt v

evalTests = TestList
    [ 
      (tInt 3) `eql` (mint 3),
      ((tInt 5) + (tInt 5)) `eql` (mint 10),
      (((tInt 8) - (tInt 5)) + (tInt 5)) `eql` (mint 8),
      (((tInt 8) - (tInt 5)) .> (tInt 5)) `eql` T.tclFalse,
      "5 >= 5 -> true" ~: ((tInt 5) .>= (tInt 5)) `eql` (T.tclTrue),
      "5 <= 5 -> true" ~: ((tInt 5) .<= (tInt 5)) `eql` (T.tclTrue),
      ((tInt 6) .<= (tInt 5)) `eql` (T.tclFalse),
      "8 - 5 < 5 -> true" ~: (((tInt 8) - (tInt 5)) .< (tInt 5)) `eql` T.tclTrue
    ]
 where eql a b = (runExpr a (return . T.mkTclBStr)) ~=? Just b

varEvalTests = TestList
    [ 
      "$num -> 4" ~: (TVar "num") `eql` (mint 4),
      ((TVar "num") + (tInt 3)) `eql` (mint 7),
      ((tInt 4) + ((TVar "num") - (tInt 1))) `eql` (mint 7),
      "$boo == \"bean\" -> true" ~: ((TVar "boo") `eq` (tStr "bean")) `eql` T.tclTrue
    ]
 where eql a b = (runExpr a lu) ~=? Just b
       table = M.fromList . mapFst pack $ [("boo", T.mkTclStr "bean"), ("num", T.mkTclInt 4)]
       lu v = M.lookup v table

riExpr s f = expr s >>= \e -> runExpr e f

exprParseTests = TestList [ aNumberTests, stringTests, varTests, exprTests, evalTests, varEvalTests ]

-- howbout s = parse pexpr "" s
