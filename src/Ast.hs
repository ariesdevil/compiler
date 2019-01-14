module Ast where 

import Prelude hiding (id)
import Text.Parsec.Pos
import Data.List
import Data.Char
import Debug.Pretty.Simple (pTraceShowId, pTraceShow)

type StringToken = (SourcePos, String)
type NumberToken = (SourcePos, (Either Integer Double))

data KeliDecl 
    = KeliConstDecl KeliConst
    | KeliFuncDecl KeliFunc
    | KeliIdlessDecl KeliExpr
    deriving (Show)

data KeliConst = KeliConst { 
    constDeclId    :: StringToken, -- because we can ignore the identifier
    constDeclValue :: KeliExpr,
    constDeclType  :: Maybe KeliType
} deriving (Show)

type KeliFuncDeclParam = (StringToken, KeliType)
type KeliFuncDeclConstraint = (StringToken, KeliType)

data KeliFunc = KeliFunc {
    funcDeclGenericParams :: [KeliFuncDeclConstraint],
    funcDeclParams        :: [KeliFuncDeclParam],
    funcDeclIds           :: [StringToken],
    funcDeclReturnType    :: KeliType,
    funcDeclBody          :: KeliExpr
} deriving (Show, Eq)


data KeliType  
    = KeliTypeUnverified KeliExpr
    | KeliTypeFloat
    | KeliTypeInt
    | KeliTypeString
    | KeliTypeRecord [(StringToken, KeliType)]
    | KeliTypeTagUnion [StringToken] -- list of tags
    | KeliTypeAlias StringToken 
    | KeliTypeSingleton StringToken
    | KeliTypeUndefined
    | KeliTypeCarryfulTagConstructor 
        StringToken  -- tag
        KeliType     -- carry type
        KeliType     -- belonging type

    | KeliTypeRecordConstructor [(StringToken, KeliType)]
    | KeliTypeConstraint KeliConstraint 
    deriving (Show, Eq)

data KeliConstraint
    = KeliConstraintAny
    | KeliConstraintUnverified KeliExpr
    deriving (Show, Eq)


data KeliTag
    = KeliTagCarryless 
        StringToken -- tag
        KeliType    -- belonging type

    | KeliTagCarryful
        StringToken -- tag
        KeliType    -- carry type
        KeliType    -- beloging type
            deriving (Show, Eq)

data KeliExpr 
    = KeliNumber NumberToken 
    | KeliString StringToken
    | KeliId     StringToken
    | KeliFuncCall {
        funcCallParams :: [KeliExpr],
        funcCallIds    :: [StringToken],
        funcCallRef    :: Maybe KeliFunc
    }
    | KeliLambda {
        lambdaParams :: [StringToken],
        lambdaBody   :: KeliExpr
    }
    | KeliRecord {
        recordKeyValues :: [(StringToken, KeliExpr)]
    }
    | KeliRecordGetter {
        recordGetterSubject      :: KeliExpr,
        recordGetterPropertyName :: StringToken
    }
    | KeliRecordSetter {
        recordSetterSubject      :: KeliExpr,
        recordSetterPropertyName :: StringToken,
        recordSetterNewValue     :: KeliExpr
    }
    | KeliTagMatcher {
        tagMatcherSubject    :: KeliExpr,
        tagMatcherBranches   :: [(StringToken, KeliExpr)], -- [(Tag, KeliExpr)]
        tagMatcherElseBranch :: Maybe KeliExpr
    } 
    | KeliTagConstructor {
        tagConstructorId    :: StringToken,
        tagConstructorCarry :: Maybe KeliExpr
    } 
    | KeliTypeCheckedExpr {
        _expr :: KeliExpr,
        _type :: KeliType
    }
    | KeliTypeExpr KeliType

    | KeliCarrylessTagDeclExpr 
        StringToken -- tag

    | KeliCarryfulTagDeclExpr
        StringToken -- tag
        KeliType    -- carry

    | KeliTagUnionDeclExpr [KeliTag]

    | KeliRecordConstructor [(StringToken, KeliType)]

    deriving (Show, Eq)


class Identifiable a where
    getIdentifier :: a -> StringToken

instance Identifiable KeliDecl where
    getIdentifier d = case d of
        KeliConstDecl c -> getIdentifier c
        KeliFuncDecl  f -> getIdentifier f

-- Each function identifier shall follows the following format:
--
--      <front part>$$<back part>
--      id1$id2$id3$$paramType1$paramType2$paramType3
--
--  where <front part> is function names and <back part> is param types
-- 
-- Example:
--      this:str.replace old:str with new:str | str = undefined
-- Shall have id of
--      replace$old$$str$str$str 
--
-- This format is necessary, so that when we do function lookup,
--  we can still construct back the function details from its id when needed
--  especially when looking up generic functions
instance Identifiable KeliFunc where
    getIdentifier (KeliFunc{funcDeclIds=ids, funcDeclParams=params})
        = (
            fst (head ids)
            ,
            intercalate "$" (map (toValidJavaScriptId . snd) ids) ++ "$$" ++ intercalate "$" (map (toString . snd) params) 
        )

-- Basically, this function will convert all symbols to its corresponding ASCII code
-- e.g. toValidJavaScriptId "$" = "_36"
toValidJavaScriptId :: String -> String
toValidJavaScriptId s = "_" ++ intercalate [] (map (\x -> if isSymbol x then show (ord x) else [x]) s)


instance Identifiable KeliConst where
    getIdentifier c = constDeclId c



instance Identifiable KeliType where
    getIdentifier x = (newPos "" (-1) (-1), toString x)


-- What is toString for?
-- It is for generating the identifier for each particular functions
-- For example, the following function:
--     this:str.reverse = undefined
-- Will have an id of something like _reverse_str
-- So that the function lookup process can be fast (during analyzing function call)

class Stringifiable a where
    toString :: a -> String

instance Stringifiable KeliType where
    toString t = case t of
        KeliTypeFloat  -> "float"
        KeliTypeInt    -> "int"
        KeliTypeString -> "str"
        KeliTypeRecord kvs -> undefined
        KeliTypeTagUnion tags -> undefined 
        KeliTypeAlias (_,id) -> id
        KeliTypeUnverified expr -> "unknown" -- error (show expr)
        KeliTypeConstraint c -> toString c
        _ -> undefined

-- For constraint type, we just return an empty string
instance Stringifiable KeliConstraint where
    toString _ = ""