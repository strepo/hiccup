{-# LANGUAGE BangPatterns #-}
module TclLib.ControlProcs (controlCmds) where

import Common
import Core
import Match (globMatch, exactMatch)
import Control.Monad.Error
import qualified TclObj as T
import TclErr
import TclObj ((.==))
import TclLib.LibUtil
import Util

controlCmds = makeCmdList $
  [("while", cmdWhile), ("if", cmdIf), 
   ("for", cmdFor), ("foreach", cmdForEach), 
   ("switch", cmdSwitch)]

cmdIf (cond:yes:rest) = do
  condVal <- doCond cond
  if condVal then evalTcl yes
    else case rest of
          []      -> ret
          [s,blk] -> if (T.asBStr s) == (pack "else") then evalTcl blk else tclErr "Invalid If"
          (s:r)   -> if s .== "elseif" then cmdIf r else tclErr "Invalid If"
cmdIf _ = argErr "if"


cmdWhile args = case args of
  [cond,body] -> whileLoop cond body
  _           -> argErr "while"

whileLoop cond body = loop `catchError` herr
 where herr e = case toEnum (errCode e) of
           EBreak    -> ret
           EContinue -> loop `catchError` herr
           _         -> throwError e
       loop = do
         condVal <- doCond cond
         if condVal then evalTcl body >> loop else ret

eatErr f v = (f >> ret) `catchError` \e -> if v == (toEnum (errCode e)) then ret else throwError e
{-# INLINE eatErr #-}

cmdFor args = case args of
   [start,test,next,body] -> do evalTcl start
                                loop test next body `eatErr` EBreak
                                ret
   _                      -> argErr "for"
 where loop test next body = do
         c <- doCond test
         if c then (evalTcl body `eatErr` EContinue) >> evalTcl next >> loop test next body
              else ret

cmdForEach args =
   case args of
    [vl_,l_,block] -> do
               vl <- T.asList vl_
               l <- T.asList l_
               let vllen = length vl
               if vllen == 1
                   then allowBreak (mapM_ (doSingl (head vl) block) l)
                   else do
                      let chunks = l `chunkBy` vllen
                      allowBreak (mapM_ (doChunk vl block) chunks)
               ret
    _            -> argErr "foreach"
 where allowBreak f = f `eatErr` EBreak
       doChunk vl block items = do zipWithM_ (\a b -> varSetNS (T.asVarName a) b) vl (items ++ repeat T.empty)
                                   evalTcl block `eatErr` EContinue
       doSingl v block i = do varSetNS (T.asVarName v) i
                              evalTcl block `eatErr` EContinue

chunkBy lst n = let (a,r) = splitAt n lst
                in a : (if null r then [] else r `chunkBy` n)

cmdSwitch args = case args of
   [str,pairlst]     -> T.asList pairlst >>= doSwitch (exacter str) 
   [opt,str,pairlst] -> if opt .== "--" || opt .== "-exact"
                         then T.asList pairlst >>= doSwitch (exacter str) 
                         else if opt .== "-glob" 
                                 then T.asList pairlst >>= doSwitch (globber str)
                                 else tclErr $ "switch: bad option " ++ show opt
   _                 -> argErr "switch"
 where globber s = let bs = T.asBStr s in \o -> globMatch (T.asBStr o) bs
       exacter s = let bs = T.asBStr s in \o -> exactMatch (T.asBStr o) bs

doSwitch matchP lst = do 
   pl <- toPairs lst
   switcher pl False
 where switcher [(k,v)] useNext = do
         if matchP k || useNext || k .== "default"
             then if v .== "-" then tclErr $ "no body specified for pattern " ++ show k
                               else evalTcl v
             else ret
       switcher ((k,v):xs) useNext = do
         if matchP k || useNext
             then if v .== "-" then switcher xs True else evalTcl v
             else switcher xs False
       switcher []      _       = tclErr "impossible condition in \"switch\""

toPairs [a,b]   = return [(a,b)]
toPairs (a:b:r) = liftM ((a,b):) (toPairs r)
toPairs _       = tclErr "list must have even number of elements"