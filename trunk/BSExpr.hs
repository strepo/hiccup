{-# LANGUAGE BangPatterns,OverloadedStrings #-}
module BSExpr (Atom(..),Expr(..)
       ,Exprable(..)
       ,TNum(..)
       ,parseFullExpr
       ,parseExpr
       ,exprToLisp
       ,bsExprTests) where

import BSParse
import TclParse
import VarName
import Util hiding (orElse)
import qualified Data.ByteString.Char8 as B
import qualified Data.Map as M
import Expr.TExp (Op(..), UnOp(..))
import Test.HUnit 

class Exprable e where
  asExpr :: (Monad m) => e -> m Expr

{-
instance Exprable B.ByteString where
  asExpr s = case parseExpr s of
               Right (e,_) -> return e
               Left err -> fail err
-}

data TNum = TInt !Int | TDouble !Double deriving (Show,Eq)

consumed :: Parser t -> Parser BString
consumed p s = do 
    (_,r) <- p s 
    let lendiff = B.length s - B.length r
    return (B.take lendiff s, r)

parseNum :: Parser TNum
parseNum s = do
   (i,r) <- parseInt s
   (dubpart i) `orElse` (emit (TInt i)) $ r
 where dubpart i = dtail `wrapWith` (\v -> TDouble (fromIntegral i + (read ('0':v))))
       dtail = (consumed (pchar '.' .>> digstring)) `wrapWith` B.unpack
       digstring = getPred1 (`elem` "0123456789")  "digit"

parseInt :: Parser Int 
parseInt s = case B.readInt s of
                Just x -> return x
                Nothing -> fail "expected int"

parseDouble :: Parser Double
parseDouble s = do
   (i,r) <- parseInt s
   (dt,r2) <- dtail r
   return (fromIntegral i + (read ('0':dt)), r2)
 where dtail :: Parser String 
       dtail = ((pchar '.') `pcons` digstring) `wrapWith` (map B.head)
       digstring = parseMany1 (parseOneOf "0123456789") 
   
   
   

data Atom = AStr !BString | ANum !TNum | AVar !(NSQual VarName)
           | AFun !BString Expr | ACom TokCmd deriving (Eq,Show)

data Expr = Item Atom | BinApp !Op Expr Expr | UnApp !UnOp Expr | Paren Expr deriving (Eq,Show)

operators = mkops [ 
                   [("||",OpOr), ("&&",OpAnd)]
                   ,[("==",OpEql), ("!=",OpNeql)]
                   ,[("<=", OpLte), (">=", OpGte), ("<",OpLt), (">",OpGt)]
                   ,[("eq",OpStrEq), ("ne",OpStrNe)]
                   ,[("+",OpPlus), ("-",OpMinus)]
                   ,[("*", OpTimes), ("/", OpDiv)] 
                   ]
  where mkop p (s,o) = OpDef s o p 
        mkops = concatMap (\(p,vl) -> map (mkop p) vl) . zip [0..]

getPrec = opPrec . getOp

higherPrec op1 op2 = getPrec op1 >= getPrec op2

getOp op = case M.lookup op opsByOper of
            Just v -> v
            Nothing -> error "wtf"

getOpName = B.unpack . opName . getOp
opName (OpDef n _ _) = n
opPrec (OpDef _ _ p) = p
opsByOper = M.fromList (map pairer operators)
  where pairer a@(OpDef _ o _) = (o,a)


data OpDef = OpDef BString Op Int


showExpr (Item (ANum i)) = show i
showExpr (Item (AStr i)) = show i
showExpr (Item (AFun s e)) = "(" ++ B.unpack s ++ " " ++ showExpr e ++ ")"
showExpr (Item x) = show x
showExpr (Paren e) = showExpr e
showExpr (UnApp o e) = "(" ++ show o ++ " " ++ showExpr e ++ ")"
showExpr (BinApp op a b) = showOpExpr (getOpName op) a b

showOpExpr ops a b = "(" ++ ops ++ " " ++ showExpr a ++ " " ++ showExpr b ++ ")"

exprToLisp s = case parseExpr (B.pack s) of
                Left r -> r
                Right (a,_) -> showExpr a

parseAtom = choose [str,var,cmd,num,bool,fun]
 where  atom f w = (eatSpaces .>> f) `wrapWith` w
        str = atom parseStr AStr
        num = atom parseNum ANum
        var = atom doVarParse (AVar . parseVarName)
        cmd = atom parseSub ACom
        bool = atom parseBool (ANum . TInt)
        fun = atom (pjoin (,) (getPred1 wordChar "function name") (paren parseExpr)) (\(x,y) -> AFun x y)

parseBool = (strChoose ["true","on"] .>> emit 1) `orElse` (strChoose ["false", "off"] .>> emit 0)
  where strChoose = choose . map parseLit
        
parseUnOp = notop `orElse` negop
  where negop = pchar '-' `wrapWith` (const OpNeg)
        notop = pchar '!' `wrapWith` (const OpNot)

parseItem = (parseAtom `wrapWith` Item) `orElse` ((paren parseExpr) `wrapWith` Paren) `orElse` (pjoin UnApp parseUnOp parseItem)

parseFullExpr = parseExpr `pass` (eatSpaces .>> parseEof)

parseExpr = eatSpaces .>> expTerm
 where expTerm str = do
        (i1,r) <- (parseItem `orElse` ((paren parseExpr) `wrapWith` Paren)) str
        (pjoin (\a i2 -> fixApp i1 a i2) parseOp parseExpr) `orElse` (emit i1) $ r 


fixApp a@(BinApp op2 a2 b2) op b = if op `higherPrec` op2 then (BinApp op2 a2 (BinApp op b2 b)) else BinApp op a b
fixApp a op b@(BinApp op2 a2 b2) = if op `higherPrec` op2 then (BinApp op2 (BinApp op a a2) b2) else BinApp op a b
fixApp a op b = BinApp op a b

paren p = (pchar '(' .>> p) `pass` (eatSpaces .>> pchar ')')

parseOp = eatSpaces .>> choose plist
 where sop s v = parseLit s .>> emit v
       op2parser (OpDef s o _) = sop s o
       plist = map op2parser operators


bsExprTests = "BSExpr" ~: TestList [atomTests, numTests, intTests, itemTests, exprTests] where
  int i = Item (ANum (TInt i))
  dub d = Item (ANum (TDouble d))
  str s = Item (AStr s)
  app2 a op b = BinApp op a b
  should_be_ p dat res = (B.unpack dat) ~: Right (res, "") ~=? p dat
  atomTests = TestList [
     "11" `should_be` (ANum (TInt 11))
     ,"true" `should_be` (ANum (TInt 1))
     ,"false" `should_be` (ANum (TInt 0))
     ,"sin(4)" `should_be` (AFun "sin" (int 4))
     ,"$candy" `should_be` (AVar (NSQual Nothing (VarName "candy" Nothing)))
     ,"\"what\"" `should_be` (AStr "what")
     ,"[incr x]" `should_be` (ACom (Word "incr", [Word "x"])) 
   ] where should_be = should_be_ parseAtom

  itemTests = TestList [
     "11" `should_be` (int 11)
     ,"!0" `should_be` (UnApp OpNot (int 0))
     ,"--4" `should_be` (UnApp OpNeg (int (-4)))
     ,"![is_done]" `should_be` (UnApp OpNot (Item (ACom (Word "is_done", []))))
   ] where should_be = should_be_ parseItem
 
  exprTests = TestList [
     "11" `should_be` (int 11)
     ,"(1 * 2) + 1" `should_be` (app2 (Paren (app2 (int 1) OpTimes (int 2))) OpPlus (int 1))
     ,"1 * 2 + 1" `should_be` (app2 (app2 (int 1) OpTimes (int 2)) OpPlus (int 1))
     ,"1 + 2 * 1" `should_be` (app2 (int 1) OpPlus (app2 (int 2) OpTimes (int 1)))
     ,"1 == \"1\"" `should_be` (app2 (int 1) OpEql (str "1"))
     ,"1 + 1 != \"1\"" `should_be` (app2 (app2 (int 1) OpPlus (int 1)) OpNeql (str "1"))
   ] where should_be dat res = (B.unpack dat) ~: Right (res, "") ~=? parseExpr dat
  
  numTests = TestList [
      "44" `should_be` TInt 44
      ,"44.8" `should_be` TDouble 44.8
   ] where should_be dat res = Right (res,"") ~=? parseNum dat

  intTests = TestList [
       "44" `should_be` 44
       ,"9" `should_be` 9
       ,"catfish" `should_fail` ()
    ] where should_be dat res = Right (res,"") ~=? parseInt dat
            should_fail dat () = (parseInt dat) `should_fail_` ()
