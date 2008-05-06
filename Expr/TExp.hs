module Expr.TExp where

import TclParse (TokCmd)
import VarName
import Util


data TNum = TInt !Int | TDouble !Double deriving (Show,Eq)

data Atom = AStr !BString | ANum !TNum 
             deriving (Eq,Show)

data Dep a = DCom TokCmd 
         | DFun !BString a
         | DVar !(NSQual VarName)  deriving (Eq,Show)

data Expr = Item Atom 
          | BinApp !Op Expr Expr  
          | UnApp !UnOp Expr 
          | DepItem (Dep Expr)
          | Paren Expr deriving (Eq,Show)

data Op = OpDiv | OpPlus | OpMinus | OpTimes | OpEql | OpNeql |
          OpLt | OpGt | OpLte | OpGte | OpStrNe | OpStrEq | OpAnd |
          OpOr | OpExp | OpLShift | OpRShift
  deriving (Show,Eq,Ord,Enum, Bounded)

data CExpr a m = CApp2 (a -> a -> m a) (CExpr a m) (CExpr a m) | CItem Atom 
               | CApp (a -> m a) (CExpr a m)
               | DItem (Dep (CExpr a m))

instance (Show (CExpr a m)) where
  show (DItem d) = "DItem " ++ show d
  show (CApp _ e) = "CApp (a -> m a) " ++ show e
  show (CApp2 _ e1 e2) = "CApp2 BINOP " ++ show e1 ++ " " ++ show e2
  show (CItem a) = "CItem " ++ show a 

data UnOp = OpNot | OpNeg deriving (Eq,Show)

class Exprable e where
  asExpr :: (Monad m) => e -> m Expr