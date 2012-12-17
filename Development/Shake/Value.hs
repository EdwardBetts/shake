{-# LANGUAGE ExistentialQuantification, GeneralizedNewtypeDeriving, MultiParamTypeClasses #-}

{- |
This module implements the Key/Value types, to abstract over hetrogenous data types.
-}
module Development.Shake.Value(
    Value, newValue, fromValue, typeValue,
    Key, newKey, fromKey, typeKey,
    Witness, currentWitness, registerWitness
    ) where

import Development.Shake.Binary
import Control.DeepSeq
import Data.Hashable
import Data.Typeable

import Data.Bits
import Data.Function
import Data.IORef
import Data.List
import Data.Maybe
import qualified Data.HashMap.Strict as Map
import System.IO.Unsafe


-- We deliberately avoid Typeable instances on Key/Value to stop them accidentally
-- being used inside themselves
newtype Key = Key Value
    deriving (Eq,Hashable,NFData,BinaryWith Witness)

data Value = forall a . (Eq a, Show a, Typeable a, Hashable a, Binary a, NFData a) => Value a


newKey :: (Eq a, Show a, Typeable a, Hashable a, Binary a, NFData a) => a -> Key
newKey = Key . newValue

newValue :: (Eq a, Show a, Typeable a, Hashable a, Binary a, NFData a) => a -> Value
newValue = Value

typeKey :: Key -> TypeRep
typeKey (Key v) = typeValue v

typeValue :: Value -> TypeRep
typeValue (Value x) = typeOf x

fromKey :: Typeable a => Key -> a
fromKey (Key v) = fromValue v

fromValue :: Typeable a => Value -> a
fromValue (Value x) = fromMaybe (error msg) $ cast x
    where msg = "Internal error in Shake.fromValue, bad cast"

instance Show Key where
    show (Key a) = show a

instance Show Value where
    show (Value a) = show a

instance NFData Value where
    rnf (Value a) = rnf a

instance Hashable Value where
    hashWithSalt salt (Value a) = hashWithSalt salt (typeOf a) `xor` hashWithSalt salt a

instance Eq Value where
    Value a == Value b = case cast b of
        Just bb -> a == bb
        Nothing -> False


---------------------------------------------------------------------
-- BINARY INSTANCES

{-# NOINLINE witness #-}
witness :: IORef (Map.HashMap TypeRep Value)
witness = unsafePerformIO $ newIORef Map.empty

registerWitness :: (Eq a, Show a, Typeable a, Hashable a, Binary a, NFData a) => a -> IO ()
registerWitness x = modifyIORef witness $ Map.insert (typeOf x) (Value $ undefined `asTypeOf` x)

toAscList :: Ord k => Map.HashMap k v -> [(k,v)]
toAscList = sortBy (compare `on` fst) . Map.toList


data Witness = Witness
    {typeNames :: [String] -- the canonical data, the names of the types
    ,witnessIn :: Map.HashMap Word16 Value -- for reading in, the find the values (some may be missing)
    ,witnessOut :: Map.HashMap TypeRep Word16 -- for writing out, find the value
    }

instance Eq Witness where
    -- type names are ordered by TypeRep values, so should to remain reasonably consistent
    -- regardless of the order of registerWitness calls
    a == b = typeNames a == typeNames b

currentWitness :: IO Witness
currentWitness = do
    ws <- readIORef witness
    let (ks,vs) = unzip $ toAscList ws
    return $ Witness (map show ks) (Map.fromList $ zip [0..] vs) (Map.fromList $ zip ks [0..])


instance Binary Witness where
    put (Witness ts _ _) = put ts
    get = do
        ts <- get
        let ws = toAscList $ unsafePerformIO $ readIORef witness
        let (is,ks,vs) = unzip3 [(i,k,v) | (i,t) <- zip [0..] ts, (k,v):_ <- [filter ((==) t . show . fst) ws]]
        return $ Witness ts (Map.fromList $ zip is vs) (Map.fromList $ zip ks is)


instance BinaryWith Witness Value where
    -- FIXME: Should probably be writing out bytes, rather than 64 bit Int's
    putWith ws (Value x) = do
        let msg = "Internal error, could not find witness type for " ++ show (typeOf x)
        put $ fromMaybe (error msg) $ Map.lookup (typeOf x) (witnessOut ws)
        put x

    getWith ws = do
        h <- get
        case Map.lookup h $ witnessIn ws of
            Nothing | h >= 0 && h < genericLength (typeNames ws) -> error $
                "Failed to find a type " ++ (typeNames ws !! fromIntegral h) ++ " which is stored in the database.\n" ++
                "The most likely cause is that your build tool has changed significantly."
            Nothing -> error $
                -- should not happen, unless proper data corruption
                "Corruption when reading Value, got type " ++ show h ++ ", but should be in range 0.." ++ show (length (typeNames ws) - 1)
            Just (Value t) -> do
                x <- get
                return $ Value $ x `asTypeOf` t
