{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections       #-}


-- TODO: consider moving this module to common package
module HStream.SpecUtils where

import           Control.Concurrent
import           Control.Exception                (Exception, bracket, bracket_)
import           Control.Monad
import qualified Data.Aeson                       as Aeson
import qualified Data.ByteString                  as BS
import qualified Data.ByteString.Char8            as BSC
import qualified Data.ByteString.Internal         as BS
import qualified Data.ByteString.Lazy.Char8       as BSCL
import qualified Data.HashMap.Strict              as HM
import           Data.IORef
import qualified Data.Map.Strict                  as Map
import           Data.Maybe                       (fromMaybe)
import           Data.Text                        (Text)
import qualified Data.Text                        as Text
import qualified Data.Text.Encoding               as Text
import qualified Data.Text.Lazy                   as TL
import qualified Data.Vector                      as V
import qualified Database.ClickHouseDriver.Client as ClickHouse
import qualified Database.ClickHouseDriver.Types  as ClickHouse
import qualified Database.MySQL.Base              as MySQL
import           Network.GRPC.HighLevel.Generated
import           Network.GRPC.LowLevel.Call       (clientCallCancel)
import           Proto3.Suite                     (def)
import           System.Environment               (lookupEnv)
import qualified System.IO.Streams                as Streams
import           System.IO.Unsafe                 (unsafePerformIO)
import           System.Random
import           Test.Hspec

import           HStream.Client.Action
import           HStream.SQL
import           HStream.Server.HStreamApi
import           HStream.ThirdParty.Protobuf      (Empty (Empty), Struct (..),
                                                   Value (Value),
                                                   ValueKind (ValueKindStructValue))
import           HStream.Utils

clientConfig :: ClientConfig
clientConfig = unsafePerformIO $ do
  port <- read . fromMaybe "6570" <$> lookupEnv "SERVER_LOCAL_PORT"
  let host = "127.0.0.1"
  let config = ClientConfig { clientServerHost = Host host
                            , clientServerPort = Port port
                            , clientArgs = []
                            , clientSSLConfig = Nothing
                            , clientAuthority = Nothing
                            }
  withGRPCClient config $ \client -> do
    HStreamApi{..} <- hstreamApiClient client
    let req = EchoRequest "hi"
    resp <- hstreamApiEcho (ClientNormalRequest req 5 (MetadataMap Map.empty))
    case resp of
      ClientNormalResponse _echoResponse _meta1 _meta2 _status _details ->
        return config
      ClientErrorResponse _clientError -> do
        let addr = BSC.unpack host <> ":" <> show port
        error $ "Connect to server " <> addr <> " failed. "
             <> "Make sure you have run hstream server on " <> addr
{-# NOINLINE clientConfig #-}

mysqlConnectInfo :: MySQL.ConnectInfo
mysqlConnectInfo = unsafePerformIO $ do
  port <- read . fromMaybe "3306" <$> lookupEnv "MYSQL_LOCAL_PORT"
  return $ MySQL.ConnectInfo { ciUser = "root"
                             , ciPassword = ""
                             , ciPort = port
                             , ciHost = "127.0.0.1"
                             , ciDatabase = "mysql"
                             , ciCharset = 33
                             }
{-# NOINLINE mysqlConnectInfo #-}

createMySqlConnectorSql :: TL.Text -> TL.Text -> TL.Text
createMySqlConnectorSql name stream
  = "CREATE SINK CONNECTOR " <> name <> " WITH (type=mysql, "
 <> "host=" <> TL.pack (show $ MySQL.ciHost mysqlConnectInfo) <> ","
 <> "port=" <> TL.pack (show $ MySQL.ciPort mysqlConnectInfo) <> ","
 <> "username=" <> TL.pack (show $ MySQL.ciUser mysqlConnectInfo) <> ","
 <> "password=" <> TL.pack (show $ MySQL.ciPassword mysqlConnectInfo) <> ","
 <> "database=" <> TL.pack (show $ MySQL.ciDatabase mysqlConnectInfo) <> ","
 <> "stream=" <> stream
 <> ");"

clickHouseConnectInfo :: ClickHouse.ConnParams
clickHouseConnectInfo = unsafePerformIO $ do
  port <- BSC.pack . fromMaybe "9000" <$> lookupEnv "CLICKHOUSE_LOCAL_PORT"
  return $ ClickHouse.ConnParams { username'    = "default"
                                 , host'        = "127.0.0.1"
                                 , port'        = port
                                 , password'    = ""
                                 , compression' = False
                                 , database'    = "default"
                                 }
{-# NOINLINE clickHouseConnectInfo #-}

createClickHouseConnectorSql :: TL.Text -> TL.Text -> TL.Text
createClickHouseConnectorSql name stream
  = "CREATE SINK CONNECTOR " <> name <> " WITH (type=clickhouse, "
 <> "host=" <> TL.pack (show $ ClickHouse.host' clickHouseConnectInfo) <> ","
 <> "port=" <> TL.fromStrict (Text.decodeUtf8 $ ClickHouse.port' clickHouseConnectInfo) <> ","
 <> "username=" <> TL.pack (show $ ClickHouse.username' clickHouseConnectInfo) <> ","
 <> "password=" <> TL.pack (show $ ClickHouse.password' clickHouseConnectInfo) <> ","
 <> "database=" <> TL.pack (show $ ClickHouse.database' clickHouseConnectInfo) <> ","
 <> "stream=" <> stream
 <> ");"

newRandomText :: Int -> IO Text
newRandomText n = Text.pack . take n . randomRs ('a', 'z') <$> newStdGen

newRandomLazyText :: Int -> IO TL.Text
newRandomLazyText n = TL.fromStrict <$> newRandomText n

newRandomByteString :: Int -> IO BS.ByteString
newRandomByteString n = BS.pack <$> replicateM n (BS.c2w <$> randomRIO ('a', 'z'))

-------------------------------------------------------------------------------

provideHstreamApi :: ActionWith (HStreamApi ClientRequest ClientResult) -> IO ()
provideHstreamApi runTest = withGRPCClient clientConfig $ runTest <=< hstreamApiClient

provideRunTest_
  :: (HStreamClientApi -> IO a)
  -> (HStreamClientApi -> IO ())
  -> ActionWith HStreamClientApi
  -> HStreamClientApi
  -> IO ()
provideRunTest_ setup clean runTest api =
  bracket_ (setup api) (clean api) (runTest api)

provideRunTest
  :: (HStreamClientApi -> IO a)
  -> (HStreamClientApi -> a -> IO ())
  -> ((HStreamClientApi, a) -> IO ())
  -> HStreamClientApi
  -> IO ()
provideRunTest setup clean runTest api =
  bracket (setup api) (clean api) (runTest . (api,))

mkQueryReqSimple :: TL.Text -> ClientRequest 'Normal CommandQuery a
mkQueryReqSimple sql =
  let req = CommandQuery{ commandQueryStmtText = sql }
   in ClientNormalRequest req 5 (MetadataMap Map.empty)

runQuerySimple :: HStreamClientApi -> TL.Text -> IO (ClientResult 'Normal CommandQueryResponse)
runQuerySimple HStreamApi{..} sql = hstreamApiExecuteQuery $ mkQueryReqSimple sql

runQuerySimple_ :: HStreamClientApi -> TL.Text -> IO ()
runQuerySimple_ HStreamApi{..} sql = do
  hstreamApiExecuteQuery (mkQueryReqSimple sql) `grpcShouldReturn` querySuccessResp

querySuccessResp :: CommandQueryResponse
querySuccessResp = CommandQueryResponse V.empty

grpcShouldReturn
  :: (HasCallStack, Show a, Eq a)
  => IO (ClientResult 'Normal a) -> a -> Expectation
action `grpcShouldReturn` expected = (getServerResp =<< action) `shouldReturn` expected

grpcShouldThrow
  :: (HasCallStack, Exception e)
  => IO (ClientResult 'Normal a) -> Selector e -> Expectation
action `grpcShouldThrow` p = (getServerResp =<< action) `shouldThrow` p

-------------------------------------------------------------------------------

mkStruct :: [(Text, Aeson.Value)] -> Struct
mkStruct = jsonObjectToStruct . HM.fromList

mkViewResponse :: Struct -> CommandQueryResponse
mkViewResponse = CommandQueryResponse . V.singleton . structToStruct "SELECTVIEW"

executeCommandQuery :: TL.Text -> IO (Maybe CommandQueryResponse)
executeCommandQuery sql = withGRPCClient clientConfig $ \client -> do
  HStreamApi{..} <- hstreamApiClient client
  let commandQuery = CommandQuery{ commandQueryStmtText = sql }
  resp <- hstreamApiExecuteQuery (ClientNormalRequest commandQuery 100 (MetadataMap Map.empty))
  case resp of
    ClientNormalResponse x@CommandQueryResponse{} _meta1 _meta2 _status _details ->
      return $ Just x
    ClientErrorResponse clientError -> do
      putStrLn $ "Client Error: " <> show clientError
      return Nothing

executeCommandQuery' :: TL.Text -> IO CommandQueryResponse
executeCommandQuery' sql = withGRPCClient clientConfig $ \client -> do
  HStreamApi{..} <- hstreamApiClient client
  let commandQuery = CommandQuery{ commandQueryStmtText = sql }
  resp <- hstreamApiExecuteQuery (ClientNormalRequest commandQuery 100 (MetadataMap Map.empty))
  case resp of
    ClientNormalResponse x _meta1 _meta2 StatusOk _details -> return x
    ClientNormalResponse _resp _meta1 _meta2 _status _details -> do
      error $ "Impossible happened..." <> show _status
    ClientErrorResponse err -> error $ "Server error happened: " <> show err

executeCommandPushQuery :: TL.Text -> IO [Struct]
executeCommandPushQuery sql = withGRPCClient clientConfig $ \client -> do
  HStreamApi{..} <- hstreamApiClient client
  let commandPushQuery = CommandPushQuery{ commandPushQueryQueryText = sql }
  ref <- newIORef []
  ClientReaderResponse _meta _status _details <-
    hstreamApiExecutePushQuery $
      ClientReaderRequest commandPushQuery 15
                          (MetadataMap Map.empty) (action (15.0 :: Double) ref)
  readIORef ref
  where
    action timeout ref call _meta recv
      | timeout <= 0 = clientCallCancel call
      | otherwise = do
          msg <- recv
          case msg of
            Right Nothing     -> do
              threadDelay 500000
              action (timeout - 0.5) ref call _meta recv
              return ()
            Right (Just (Struct kvmap)) -> do
              threadDelay 500000
              -- Note: remove "SELECT" tag in returned result
              case snd $ head (Map.toList kvmap) of
                (Just (Value (Just (ValueKindStructValue resp)))) -> do
                  modifyIORef ref (\xs -> xs ++ [resp])
                  action (timeout - 0.5) ref call _meta recv
                  return ()
                _ -> error "unknown data encountered"
            _ -> return ()

createMysqlTable :: Text -> IO ()
createMysqlTable source = bracket (MySQL.connect mysqlConnectInfo) MySQL.close $ \conn ->
  void $ MySQL.execute_ conn $
    MySQL.Query . BSCL.pack $ "CREATE TABLE IF NOT EXISTS "
                           <> Text.unpack source
                           <> "(temperature INT, humidity INT) CHARACTER SET utf8"

dropMysqlTable :: Text -> IO ()
dropMysqlTable name = bracket (MySQL.connect mysqlConnectInfo) MySQL.close $ \conn ->
  void $ MySQL.execute_ conn $ MySQL.Query . BSCL.pack $ "DROP TABLE IF EXISTS " <> Text.unpack name

fetchMysql :: Text -> IO [[MySQL.MySQLValue]]
fetchMysql source = bracket (MySQL.connect mysqlConnectInfo) MySQL.close $ \conn -> do
  (_, items) <- MySQL.query_ conn $ MySQL.Query . BSCL.pack $ "SELECT * FROM " <> Text.unpack source
  Streams.fold (\xs x -> xs ++ [x]) [] items

createClickHouseTable :: Text -> IO ()
createClickHouseTable source =
  bracket (ClickHouse.createClient clickHouseConnectInfo) ClickHouse.closeClient $ \conn ->
    void $ ClickHouse.query conn ("CREATE TABLE IF NOT EXISTS " ++ Text.unpack source ++
                                  " (temperature Int64, humidity Int64) " ++ "ENGINE = Memory")

dropClickHouseTable :: Text -> IO ()
dropClickHouseTable source =
  bracket (ClickHouse.createClient clickHouseConnectInfo) ClickHouse.closeClient $ \conn -> do
    void $ ClickHouse.query conn $ "DROP TABLE IF EXISTS " <> Text.unpack source

fetchClickHouse :: Text -> IO (V.Vector (V.Vector ClickHouse.ClickhouseType))
fetchClickHouse source =
  bracket (ClickHouse.createClient clickHouseConnectInfo) ClickHouse.closeClient $ \conn -> do
    q <- ClickHouse.query conn $ "SELECT * FROM " <> Text.unpack source <> " ORDER BY temperature"
    case q of
      Right res -> return res
      _         -> return V.empty

--------------------------------------------------------------------------------

runCreateStreamSql :: HStreamClientApi -> TL.Text -> Expectation
runCreateStreamSql api sql = do
  CreatePlan sName rFac <- streamCodegen $ TL.toStrict sql
  createStream api sName rFac `grpcShouldReturn`
    def { streamStreamName = TL.fromStrict sName,
          streamReplicationFactor = fromIntegral rFac}

runInsertSql :: HStreamClientApi -> TL.Text -> Expectation
runInsertSql api sql = do
  InsertPlan sName insertType payload <- streamCodegen $ TL.toStrict sql
  resp <- getServerResp =<< insertIntoStream api sName insertType payload
  appendResponseStreamName resp `shouldBe` TL.fromStrict sName

runCreateWithSelectSql :: HStreamClientApi -> TL.Text -> Expectation
runCreateWithSelectSql api sql = do
  RQCreate (RCreateAs stream _ rOptions) <- parseAndRefine $ TL.toStrict sql
  resp <- getServerResp =<< createStreamBySelect api (TL.fromStrict stream) (rRepFactor rOptions) (words $ TL.unpack sql)
  createQueryStreamResponseQueryStream resp `shouldBe`
    Just def { streamStreamName = TL.fromStrict stream
             , streamReplicationFactor = fromIntegral $ rRepFactor rOptions}

runShowStreamsSql :: HStreamClientApi -> TL.Text -> IO String
runShowStreamsSql api sql = do
  ShowPlan SStreams <- streamCodegen $ TL.toStrict sql
  formatResult 0 <$> listStreams api

runShowViewsSql :: HStreamClientApi -> TL.Text -> IO String
runShowViewsSql api sql = do
  ShowPlan SViews <- streamCodegen $ TL.toStrict sql
  formatResult 0 <$> listViews api

runDropSql :: HStreamClientApi -> TL.Text -> Expectation
runDropSql api sql = do
  DropPlan checkIfExists dropObj <- streamCodegen $ TL.toStrict sql
  dropAction api checkIfExists dropObj `grpcShouldReturn` Empty
