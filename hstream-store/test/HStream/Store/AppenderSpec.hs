{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}

module HStream.Store.AppenderSpec where

import qualified HStream.Store           as S
import           HStream.Store.SpecUtils
import           Test.Hspec

spec :: Spec
spec = describe "Stream Writer" $ do
  let logid = 1

  it "append and read" $ do
    _ <- S.append client logid "hello" Nothing
    readPayload logid Nothing `shouldReturn` "hello"

  it "appendBS and read" $ do
    _ <- S.appendBS client logid "hello" Nothing
    readPayload logid Nothing `shouldReturn` "hello"

  it "appendBatch" $ do
    _ <- S.appendBatch client logid ["hello", "world"] S.CompressionLZ4 Nothing
    readPayload' logid Nothing `shouldReturn` ["hello", "world"]

  it "appendBatchBS" $ do
    _ <- S.appendBatchBS client logid ["hello", "world"] S.CompressionLZ4 Nothing
    readPayload' logid Nothing `shouldReturn` ["hello", "world"]
