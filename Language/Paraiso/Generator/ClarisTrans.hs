{-# LANGUAGE FlexibleContexts, ImpredicativeTypes,
MultiParamTypeClasses, NoImplicitPrelude, OverloadedStrings,
RankNTypes #-}

{-# OPTIONS -Wall #-}
module Language.Paraiso.Generator.ClarisTrans (      
  Translatable(..), paren, joinBy, joinEndBy, headerFile, sourceFile
  ) where

import qualified Data.Dynamic as Dyn
import qualified Data.List as L
import qualified Data.ListLike as LL
import qualified Data.ListLike.String as LL
import           Language.Paraiso.Generator.ClarisDef
import           Language.Paraiso.Name
import           Language.Paraiso.Prelude

class Translatable a where
  translate :: Context -> a -> Text

data Context 
  = Context 
    { fileType :: FileType
    }

headerFile :: Context
headerFile = Context {fileType = HeaderFile}

sourceFile :: Context
sourceFile = Context {fileType = SourceFile}


instance Translatable Program where
  translate conf Program{topLevel = xs} = LL.unlines $ map (translate conf) xs

instance Translatable Statement where    
  translate conf stmt = case stmt of
    StmtPrpr   x             -> translate conf x ++ "\n"
    UsingNamespace x         -> "using namespace " ++ nameText x ++ ";"
    FuncDecl   x             -> translate conf x 
    StmtExpr x               -> translate conf x ++ ";"
    StmtReturn x             -> "return " ++ translate conf x                 ++ ";"
    StmtWhile test xs        -> "while" 
      ++ paren Paren (translate conf test) 
      ++ paren Brace (joinEndBy "\n" $ map (translate conf) xs)
    StmtFor ini test inc xs -> "for" 
      ++ paren Paren (joinBy "; " [translate conf ini, translate conf test, translate conf inc]) 
      ++ paren Brace (joinEndBy "\n" $ map (translate conf) xs)
    Exclusive file stmt2     ->
      if file == fileType conf then translate conf stmt2 else ""

instance Translatable Preprocessing where
  translate _ prpr = case prpr of
    PrprInclude par na -> "#include " ++ paren par na
    PrprPragma  str    -> "#pragma " ++ str

instance Translatable Function where
  translate conf f = ret
    where
      ret = if fileType conf == HeaderFile then funcDecl else funcDef
      funcDecl
        = LL.unwords
          [ translate conf (funcType f)
          , nameText f
          , paren Paren $ joinBy ", " $ map (translate conf . VarDecl) (funcArgs f)
          , ";"]
      funcDef 
        = LL.unwords
          [ translate conf (funcType f)
          , nameText f
          , paren Paren $ joinBy ", " $ map (translate conf . VarDecl) (funcArgs f)
          , paren Brace $ joinEndBy "\n" $ map (translate conf) $ funcBody f]


instance Translatable TypeRep where
  translate conf trp = case trp of
    UnitType x         -> translate conf x
    PtrOf x            -> translate conf x ++ " *"
    RefOf x            -> translate conf x ++ " &"
    Const x            -> "const " ++ translate conf x 
    TemplateType x ys  -> x ++ paren Chevron (joinBy ", " $ map (translate conf) ys) ++ " "
    QualifiedType qs x -> (joinEndBy " " $ map (translate conf) qs) ++ translate conf x
    UnknownType        -> error "cannot translate unknown type."
  
instance Translatable Qualifier where  
  translate _ CudaGlobal = "__global__"
  translate _ CudaDevice = "__device__"
  translate _ CudaHost   = "__host__"
  translate _ CudaShared = "__shared__"
  translate _ CudaConst  = "__constant__"


instance Translatable Dyn.TypeRep where  
  translate _ x = 
    case msum $ map ($x) typeRepDB of
      Just str -> str
      Nothing  -> error $ "cannot translate Haskell type: " ++ show x

instance Translatable Dyn.Dynamic where  
  translate _ x = 
    case msum $ map ($x) dynamicDB of
      Just str -> str
      Nothing  -> error $ "cannot translate value of Haskell type: " ++ show x

instance Translatable Expr where
  translate conf expr = ret
    where
      pt  = paren Paren . translate conf
      t :: Translatable a => a -> Text
      t   = translate conf
      ret = case expr of
        Imm x                  -> t x
        VarExpr x              -> nameText x
        VarDecl (Var typ nam)  -> LL.unwords [translate conf typ, nameText nam] 
        VarDeclCon v x         -> translate conf (VarDecl v) ++ paren Paren (translate conf x) 
        VarDeclSub v x         -> translate conf (VarDecl v) ++ " = " ++ translate conf x      
        FuncCallUsr f args     -> (nameText f++) $ paren Paren $ joinBy ", " $ map t args
        FuncCallStd f args     -> (f++) $ paren Paren $ joinBy ", " $ map t args
        CudaFuncCallUsr  f numBlock numThread args 
                               -> nameText f ++ paren Chevron3 (t numBlock ++ "," ++ t numThread) ++
                                  (paren Paren $ joinBy ", " $ map t args)
        Member x y             -> pt x ++ "." ++ t y
        Op1Prefix op x         -> op ++ pt x
        Op1Postfix op x        -> pt x ++ op
        Op2Infix op x y        -> LL.unwords [pt x, op, pt y]
        Op3Infix op1 op2 x y z -> LL.unwords [pt x, op1, pt y, op2, pt z]
        ArrayAccess x y        -> pt x ++ paren Bracket (t y)

-- | The databeses for Haskell -> Cpp type name translations.
typeRepDB:: [Dyn.TypeRep -> Maybe Text]
typeRepDB = map fst symbolDB

-- | The databeses for Haskell -> Cpp immediate values translations.
dynamicDB:: [Dyn.Dynamic -> Maybe Text]
dynamicDB = map snd symbolDB

-- | The united database for translating Haskell types and immediate values to Cpp
symbolDB:: [(Dyn.TypeRep -> Maybe Text, Dyn.Dynamic -> Maybe Text)]
symbolDB = [ 
  add "void"          (\() -> ""),
  add "bool"          (\x->if x then "true" else "false"),
  add "int"           (showT::Int->Text), 
  add "long long int" (showT::Integer->Text), 
  add "float"         ((++"f").showT::Float->Text), 
  add "double"        (showT::Double->Text),
  add "std::string"   (showT::String->Text),
  add "std::string"   (showT::Text->Text)
       ]  
  where
    add ::  (Dyn.Typeable a) => Text -> (a->Text) 
        -> (Dyn.TypeRep -> Maybe Text, Dyn.Dynamic -> Maybe Text)
    add = add' undefined
    add' :: (Dyn.Typeable a) => a -> Text -> (a->Text) 
        -> (Dyn.TypeRep -> Maybe Text, Dyn.Dynamic -> Maybe Text)
    add' dummy typename f = 
      (\tr -> if tr == Dyn.typeOf dummy then Just typename else Nothing,
       fmap f . Dyn.fromDynamic)


-- | an parenthesizer for lazy person.
paren :: Parenthesis -> Text -> Text
paren p str = prefix ++ str ++ suffix
  where
    (prefix,suffix) = case p of
      Paren      -> ("(",")")
      Bracket    -> ("[","]")
      Brace      -> ("{","}")
      Chevron    -> ("<",">")
      Chevron2   -> ("<<",">>")
      Chevron3   -> ("<<<",">>>")
      Quotation  -> ("\'","\'")
      Quotation2 -> ("\"","\"")

joinBy :: Text -> [Text] -> Text
joinBy sep xs = LL.concat $ L.intersperse sep xs

joinEndBy :: Text -> [Text] -> Text
joinEndBy sep xs = joinBy sep xs ++ sep
