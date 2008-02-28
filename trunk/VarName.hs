{-# LANGUAGE BangPatterns #-}
module VarName (parseVarName, 
                nsTail,
                nsQualifiers,
                parseNS,
                parseProc,
                VarName(..), 
                showVN, 
                NSQual(..), 
                NSTag(..),
                isGlobal,
                isLocal,
                explodeNS,
                splitWith,
                nsSep,
                varNameTests) where
import Util
import qualified Data.ByteString.Char8 as B
import Test.HUnit

data NSQual a = NSQual !NSTag !a deriving (Eq,Show)

data NSTag = NS ![BString] | Local deriving (Eq,Show)

data VarName = VarName { vnName :: !BString, vnInd :: Maybe BString } deriving (Eq,Show)

nsSep = pack "::"

explodeNS bstr = bstr `splitWith` nsSep
{-# INLINE explodeNS #-}

isGlobal (NS [x]) = B.null x
isGlobal _        = False
{-# INLINE isGlobal #-}

isLocal Local = True
isLocal _     = False
{-# INLINE isLocal #-}

parseVarName n = 
   let (name,ind) = parseArrRef n 
   in case parseNS name of
       Left _       -> NSQual Local (VarName name ind)
       Right (ns,n) -> NSQual (NS ns) (VarName n ind)

parseProc name =
   case parseNS name of
     Left _       -> NSQual Local name
     Right (ns,n) -> NSQual (NS ns) n

showVN :: VarName -> String
showVN (VarName name Nothing) = show name
showVN (VarName name (Just i)) = "\"" ++ unpack name ++ "(" ++ unpack i ++ ")\""

parseArrRef str = case B.elemIndex '(' str of
             Nothing    -> (str, Nothing)
             Just start -> if (start /= 0) && B.last str == ')' 
                             then let (pre,post) = B.splitAt start str
                                  in (pre, Just (B.tail (B.init post)))
                             else (str, Nothing)
nsTail str = case parseNS str of
               Left _      -> str
               Right (_,t) -> t

nsQualifiers str = case B.findSubstrings nsSep str of
                      [] -> B.empty
                      lst -> B.take (last lst) str

parseNS !str = 
  case explodeNS str of
    [str] -> Left str
    nsr   -> let (n:rx) = reverse nsr 
             in Right (reverse rx, n)
{-# INLINE parseNS #-}

splitWith :: BString -> BString -> [BString]
splitWith str sep = 
    case B.findSubstrings sep str of
        []     -> [str]
        il     -> extract il str
 where slen              = B.length sep 
       extract [] !s     = [s]
       extract (i:ix) !s = let (b,a) = B.splitAt i s 
                          in b : extract (map (\v -> v - (i+slen)) ix) (B.drop slen a)
{-# INLINE splitWith #-}
 
varNameTests = TestList [splitWithTests, testArr, testParseVarName, testParseNS, testNSTail, testNsQuals] where 
  bp = pack
  splitWithTests = TestList [
      ("one::two","::") `splitsTo` ["one","two"]
      ,("::x","::") `splitsTo` ["","x"]
      ,("wonderdragon","::") `splitsTo` ["wonderdragon"]
      ,("","::") `splitsTo` [""]
      ,("::","::") `splitsTo` ["", ""]
    ]
   where splitsTo (a,b) r = map bp r ~=? ((bp a) `splitWith` (bp b))

  testParseNS = TestList [
     parseNS (bp "boo") ~=? Left (bp "boo") 
     ,parseNS (bp "::boo") ~=? Right ([B.empty], bp "boo") 
     ,parseNS (bp "foo::boo") ~=? Right ([bp "foo"], bp "boo") 
     ,parseNS (bp "::foo::boo") ~=? Right ([bp "", bp "foo"], bp "boo") 
     ,parseNS (bp "woo::foo::boo") ~=? Right ([bp "woo", bp "foo"], bp "boo") 
   ]

  testParseVarName = TestList [
      parseVarName (bp "x") ~=? NSQual Local (VarName (bp "x") Nothing)
      ,parseVarName (bp "x(a)") ~=? NSQual Local (VarName (bp "x") (Just (bp "a")))
      ,parseVarName (bp "::x") ~=? NSQual (NS [bp ""]) (VarName (bp "x") Nothing)
    ]

  testNSTail = TestList [
       nsTail (bp "boo") ~=? (bp "boo")
       ,nsTail (bp "::boo") ~=? (bp "boo")
       ,nsTail (bp "baby::boo") ~=? (bp "boo")
       ,nsTail (bp "::baby::boo") ~=? (bp "boo")
       ,nsTail (bp "::") ~=? (bp "")
    ]
  testNsQuals = TestList [
      "boo" `should_be` ""
      ,"::" `should_be` ""
      ,"a::b" `should_be` "a"
      ,"a::b::c" `should_be` "a::b"
      ,"::a::b::c" `should_be` "::a::b"
    ]
   where should_be b a = nsQualifiers (bp b) ~=? (bp a)

  testArr = TestList [
     "december" `should_be` Nothing
     ,"dec(mber" `should_be` Nothing
     ,"dec)mber" `should_be` Nothing
     ,"(cujo)" `should_be` Nothing
     ,"de(c)mber" `should_be` Nothing
     ,"a(1)"          ?=> ("a","1")
     ,"boo(4)"        ?=> ("boo","4")
     ,"xx(september)" ?=> ("xx","september")
     ,"arr(3,4,5)"    ?=> ("arr","3,4,5")
     ,"arr()"         ?=> ("arr","")
   ]
   where (?=>) a b@(b1,b2) = (a ++ " -> " ++ show b) ~: parseArrRef (bp a) ~=? ((bp b1), Just (bp b2))
         should_be x _ =  (x ++ " should be " ++ show (bp x)) ~: parseArrRef (bp x) ~=? (bp x, Nothing)
