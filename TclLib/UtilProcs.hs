{-# LANGUAGE BangPatterns #-}
module TclLib.UtilProcs ( utilProcs ) where

import Data.Time.Clock (diffUTCTime,getCurrentTime,addUTCTime)
import Control.Monad (unless)
import Control.Concurrent (threadDelay)
import Core (evalTcl, runCmd, callProc)
import Common
import Expr (runAsExpr, CBData(..))
import qualified TclObj as T

utilProcs = makeCmdList [
   ("time", cmdTime),
   ("incr", cmdIncr), 
   ("expr", cmdExpr),
   ("after", cmdAfter), ("update", cmdUpdate)]

cmdIncr args = case args of
         [vname]     -> incr vname 1
         [vname,val] -> T.asInt val >>= incr vname
         _           -> argErr "incr"

incr :: T.TclObj -> Int -> TclM T.TclObj
incr n !i = varModify (T.asVarName n) $
                 \v -> do ival <- T.asInt v
                          return $! (T.mkTclInt (ival + i))

cmdTime args =
   case args of
     [code]     -> do tspan <- dotime code
                      return (T.mkTclStr (show tspan))
     [code,cnt] -> do count <- T.asInt cnt
                      unless (count > 0) (tclErr "invalid number of iterations in time")
                      ts <- mapM (\_ -> dotime code) [1..count]
                      let str = show ((sum ts) / fromIntegral (length ts))
                      return (T.mkTclStr (str ++ " per iteration"))
     _      -> argErr "time"
 where dotime code = do
         startt <- io getCurrentTime
         evalTcl code
         endt <- io getCurrentTime
         let tspan = diffUTCTime endt startt
         return tspan

cmdAfter args = 
    case args of 
      [mss]    -> do
            ms <- T.asInt mss
            io $ threadDelay (1000 * ms)
            ret
      (mss:acts) -> do
            ms <- T.asInt mss 
            let secs = (fromIntegral ms) / 1000.0
            currT <- io getCurrentTime
            let dline = addUTCTime secs currT
            evtAdd (T.objconcat acts) dline
      _     -> argErr "after"

cmdUpdate args = case args of
     [] -> do evts <- evtGetDue
              upglobal (mapM_ evalTcl evts)
              ret
     _  -> argErr "update"
 where upglobal f = do sl <- stackLevel
                       uplevel sl f

cmdExpr args = case args of
  [s] -> runAsExpr s exprCallback
  []  -> argErr "expr"
  _   -> runAsExpr (T.objconcat args) exprCallback

exprCallback !v = case v of
    VarRef n     -> varGetNS n
    FunRef (n,a) -> callProc n a
    CmdEval cmd  -> runCmd cmd