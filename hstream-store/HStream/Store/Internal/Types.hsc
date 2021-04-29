{-# LANGUAGE CPP             #-}
{-# LANGUAGE DeriveAnyClass  #-}
{-# LANGUAGE PatternSynonyms #-}

module HStream.Store.Internal.Types where

import           Control.Exception     (bracket, finally)
import           Control.Monad         (forM, when)
import           Data.Int
import           Data.Map.Strict       (Map)
import           Data.Word
import           Foreign.C
import           Foreign.ForeignPtr
import           Foreign.Marshal.Alloc
import           Foreign.Ptr
import           Foreign.Storable
import           GHC.Generics          (Generic)
import           Z.Data.CBytes         as CBytes
import qualified Z.Data.JSON           as JSON
import qualified Z.Data.MessagePack    as MP
import           Z.Data.Vector         (Bytes)
import qualified Z.Data.Vector         as Vec
import qualified Z.Foreign             as Z

#include "hs_logdevice.h"

-------------------------------------------------------------------------------

type C_LogID = Word64
type C_LogRange = (C_LogID, C_LogID)
type C_LogsConfigVersion = Word64

type LDClient = ForeignPtr LogDeviceClient
type LDLogGroup = ForeignPtr LogDeviceLogGroup
type LDLogAttrs = ForeignPtr LogDeviceLogAttributes
type LDVersionedConfigStore = ForeignPtr LogDeviceVersionedConfigStore

data HsLogAttrs = HsLogAttrs
  { replicationFactor :: Int
  , extraTopicAttrs   :: Map CBytes CBytes
  } deriving (Show)

data LogAttrs = LogAttrs HsLogAttrs | LogAttrsPtr LDLogAttrs

data VcsValueCallbackData = VcsValueCallbackData
  { vcsValCallbackSt  :: !ErrorCode
  , vcsValCallbackVal :: !Bytes
  }

vcsValueCallbackDataSize :: Int
vcsValueCallbackDataSize = (#size vcs_value_callback_data_t)

peekVcsValueCallbackData :: Ptr VcsValueCallbackData -> IO VcsValueCallbackData
peekVcsValueCallbackData ptr = bracket getSt release peekData
  where
    getSt = (#peek vcs_value_callback_data_t, st) ptr
    peekData st = do
      value <- if st == C_OK
                  then do len <- (#peek vcs_value_callback_data_t, val_len) ptr
                          flip Z.fromPtr len =<< (#peek vcs_value_callback_data_t, value) ptr
                  else return Vec.empty
      return $ VcsValueCallbackData st value
    release st = when (st == C_OK) $
      free =<< (#peek vcs_value_callback_data_t, value) ptr

data VcsWriteCallbackData = VcsWriteCallbackData
  { vcsWriteCallbackSt      :: !ErrorCode
  , vcsWriteCallbackVersion :: !VcsConfigVersion
  , vcsWriteCallbackValue   :: !Bytes
  }

vcsWriteCallbackDataSize :: Int
vcsWriteCallbackDataSize = (#size vcs_write_callback_data_t)

peekVcsWriteCallbackData :: Ptr VcsWriteCallbackData -> IO VcsWriteCallbackData
peekVcsWriteCallbackData ptr = bracket getSt release peekData
  where
    getSt = (#peek vcs_value_callback_data_t, st) ptr
    peekData st = do
      if (cond st)
         then do version <- (#peek vcs_write_callback_data_t, version) ptr
                 len :: Int <- (#peek vcs_write_callback_data_t, val_len) ptr
                 value <- flip Z.fromPtr len =<< (#peek vcs_write_callback_data_t, value) ptr
                 return $ VcsWriteCallbackData st version value
         else return $ VcsWriteCallbackData st C_EMPTY_VERSION Vec.empty
    release st = when (cond st) $
      free =<< (#peek vcs_write_callback_data_t, value) ptr
    cond st = st == C_OK || st == C_VERSION_MISMATCH

-------------------------------------------------------------------------------

newtype TopicID = TopicID { unTopicID :: Word64 }
  deriving (Show, Eq, Ord)

instance Bounded TopicID where
  minBound = TOPIC_ID_MIN
  maxBound = TOPIC_ID_MAX

pattern TOPIC_ID_MIN :: TopicID
pattern TOPIC_ID_MIN = TopicID 1

-- | Max valid user data logid value.
--
-- TOPIC_ID_MAX = USER_LOGID_MAX(LOGID_MAX - 1000)
pattern TOPIC_ID_MAX :: TopicID
pattern TOPIC_ID_MAX = TopicID (#const C_USER_LOGID_MAX)

pattern TOPIC_ID_INVALID :: TopicID
pattern TOPIC_ID_INVALID = TopicID (#const C_LOGID_INVALID)

pattern TOPIC_ID_INVALID' :: TopicID
pattern TOPIC_ID_INVALID' = TopicID (#const C_LOGID_INVALID2)

c_logid_max :: Word64
c_logid_max = (#const C_LOGID_MAX)

c_user_logid_max :: Word64
c_user_logid_max = (#const C_USER_LOGID_MAX)

c_logid_max_bits :: CSize
c_logid_max_bits = (#const C_LOGID_MAX_BITS)

-------------------------------------------------------------------------------

newtype StreamClient = StreamClient
  { unStreamClient :: ForeignPtr LogDeviceClient }

newtype StreamAdminClient = StreamAdminClient
  { unStreamAdminClient :: ForeignPtr LogDeviceAdminAsyncClient }

newtype RpcOptions = RpcOptions
  { unRpcOptions :: ForeignPtr ThriftRpcOptions }

newtype StreamSyncCheckpointedReader = StreamSyncCheckpointedReader
  { unStreamSyncCheckpointedReader :: ForeignPtr LogDeviceSyncCheckpointedReader }
  deriving (Show, Eq)

newtype StreamReader = StreamReader
  { unStreamReader :: ForeignPtr LogDeviceReader }
  deriving (Show, Eq)

newtype CheckpointStore = CheckpointStore
  { unCheckpointStore :: ForeignPtr LogDeviceCheckpointStore }
  deriving (Show, Eq)

newtype SequenceNum = SequenceNum { unSequenceNum :: C_LSN }
  deriving (Generic)
  deriving newtype (Show, Eq, Ord, Num, JSON.JSON, MP.MessagePack)

instance Bounded SequenceNum where
  minBound = SequenceNum c_lsn_oldest
  maxBound = SequenceNum c_lsn_max

sequenceNumInvalid :: SequenceNum
sequenceNumInvalid = SequenceNum c_lsn_invalid

newtype KeyType = KeyType C_KeyType
  deriving (Eq, Ord)

instance Show KeyType where
  show t
    | t == keyTypeFindKey = "FINDKEY"
    | t == keyTypeFilterable = "FILTERABLE"
    | otherwise = "UNDEFINED"

keyTypeFindKey :: KeyType
keyTypeFindKey = KeyType c_keytype_findkey

keyTypeFilterable :: KeyType
keyTypeFilterable = KeyType c_keytype_filterable

data DataRecord = DataRecord
  { recordLogID   :: TopicID
  , recordLSN     :: SequenceNum
  , recordPayload :: Bytes
  } deriving (Show)

dataRecordSize :: Int
dataRecordSize = (#size logdevice_data_record_t)

peekDataRecords :: Int -> Ptr DataRecord -> IO [DataRecord]
peekDataRecords len ptr = forM [0..len-1] (peekDataRecord ptr)

-- | Peek data record from a pointer and an offset, then release the payload
-- ignoring exceptions.
peekDataRecord :: Ptr DataRecord -> Int -> IO DataRecord
peekDataRecord ptr offset = finally peekData release
  where
    ptr' = ptr `plusPtr` (offset * dataRecordSize)
    peekData = do
      logid <- (#peek logdevice_data_record_t, logid) ptr'
      lsn <- (#peek logdevice_data_record_t, lsn) ptr'
      len <- (#peek logdevice_data_record_t, payload_len) ptr'
      payload <- flip Z.fromPtr len =<< (#peek logdevice_data_record_t, payload) ptr'
      return $ DataRecord (TopicID logid) (SequenceNum lsn) payload
    release = do
      payload_ptr <- (#peek logdevice_data_record_t, payload) ptr'
      free payload_ptr

data AppendCallBackData = AppendCallBackData
  { appendCbRetCode   :: !ErrorCode
  , appendCbLogID     :: !C_LogID
  , appendCbLSN       :: !C_LSN
  , appendCbTimestamp :: !C_Timestamp
  }

appendCallBackDataSize :: Int
appendCallBackDataSize = (#size logdevice_append_cb_data_t)

peekAppendCallBackData :: Ptr AppendCallBackData -> IO AppendCallBackData
peekAppendCallBackData ptr = do
  retcode <- (#peek logdevice_append_cb_data_t, st) ptr
  logid <- (#peek logdevice_append_cb_data_t, logid) ptr
  lsn <- (#peek logdevice_append_cb_data_t, lsn) ptr
  ts <- (#peek logdevice_append_cb_data_t, timestamp) ptr
  return $ AppendCallBackData retcode logid lsn ts

data LogsconfigStatusCbData = LogsconfigStatusCbData
  { logsConfigCbRetCode :: !ErrorCode
  , logsConfigCbVersion :: !Word64
  , logsConfigCbFailInfo :: !CBytes
  }

logsconfigStatusCbDataSize :: Int
logsconfigStatusCbDataSize = (#size logsconfig_status_cb_data_t)

peekLogsconfigStatusCbData :: Ptr LogsconfigStatusCbData
                           -> IO LogsconfigStatusCbData
peekLogsconfigStatusCbData ptr = do
  retcode <- (#peek logsconfig_status_cb_data_t, st) ptr
  version <- (#peek logsconfig_status_cb_data_t, version) ptr
  failinfo_ptr <- (#peek logsconfig_status_cb_data_t, failure_reason) ptr
  failinfo <- fromCString failinfo_ptr
  free failinfo_ptr
  return $ LogsconfigStatusCbData retcode version failinfo
-------------------------------------------------------------------------------

data LogDeviceClient
data LogDeviceReader
data LogDeviceSyncCheckpointedReader
data LogDeviceVersionedConfigStore
data LogDeviceLogGroup
data LogDeviceLogDirectory
data LogDeviceLogAttributes
data LogDeviceCheckpointStore
data LogDeviceAdminAsyncClient
data ThriftRpcOptions

type C_Timestamp = Int64

-- | Log Sequence Number
type C_LSN = Word64

c_lsn_invalid :: C_LSN
c_lsn_invalid = (#const C_LSN_INVALID)

c_lsn_oldest :: C_LSN
c_lsn_oldest = (#const C_LSN_OLDEST)

c_lsn_max :: C_LSN
c_lsn_max = (#const C_LSN_MAX)

type C_KeyType = Word8

c_keytype_findkey :: C_KeyType
c_keytype_findkey = (#const C_KeyType_FINDKEY)

c_keytype_filterable :: C_KeyType
c_keytype_filterable = (#const C_KeyType_FILTERABLE)

-------------------------------------------------------------------------------

type VcsConfigVersion = Word64

pattern C_EMPTY_VERSION :: VcsConfigVersion
pattern C_EMPTY_VERSION = 0

-- | Error
type ErrorCode = Word16

foreign import ccall unsafe "hs_logdevice.h show_error_name"
  c_show_error_name :: ErrorCode -> CString

foreign import ccall unsafe "hs_logdevice.h show_error_description"
  c_show_error_description :: ErrorCode -> CString

pattern
    C_OK
  , C_NOTFOUND
  , C_TIMEDOUT
  , C_NOSEQUENCER
  , C_CONNFAILED
  , C_NOTCONN
  , C_TOOBIG
  , C_TOOMANY
  , C_PREEMPTED
  , C_NOBUFS
  , C_NOMEM
  , C_INTERNAL
  , C_SYSLIMIT
  , C_TEMPLIMIT
  , C_PERMLIMIT
  , C_ACCESS
  , C_ALREADY
  , C_ISCONN
  , C_UNREACHABLE
  , C_UNROUTABLE
  , C_BADMSG
  , C_DISABLED
  , C_EXISTS
  , C_SHUTDOWN
  , C_NOTINCONFIG
  , C_PROTONOSUPPORT
  , C_PROTO
  , C_PEER_CLOSED
  , C_SEQNOBUFS
  , C_WOULDBLOCK
  , C_ABORTED
  , C_INPROGRESS
  , C_CANCELLED
  , C_NOTSTORAGE
  , C_AGAIN
  , C_PARTIAL
  , C_GAP
  , C_TRUNCATED
  , C_STALE
  , C_NOSPC
  , C_OVERLOADED
  , C_PENDING
  , C_PENDING_FULL
  , C_FAILED
  , C_SEQSYSLIMIT
  , C_REBUILDING
  , C_REDIRECTED
  , C_RETRY
  , C_BADPAYLOAD
  , C_NOSSLCONFIG
  , C_NOTREADY
  , C_DROPPED
  , C_FORWARD
  , C_NOTSUPPORTED
  , C_NOTINSERVERCONFIG
  , C_ISOLATED
  , C_SSLREQUIRED
  , C_CBREGISTERED
  , C_LOW_ON_SPC
  , C_PEER_UNAVAILABLE
  , C_NOTSUPPORTEDLOG
  , C_DATALOSS
  , C_NEVER_CONNECTED
  , C_NOTANODE
  , C_IDLE
  , C_INVALID_PARAM
  , C_INVALID_CLUSTER
  , C_INVALID_CONFIG
  , C_INVALID_THREAD
  , C_INVALID_IP
  , C_INVALID_OPERATION
  , C_UNKNOWN_SETTING
  , C_INVALID_SETTING_VALUE
  , C_UPTODATE
  , C_EMPTY
  , C_DESTINATION_MISMATCH
  , C_INVALID_ATTRIBUTES
  , C_NOTEMPTY
  , C_NOTDIR
  , C_ID_CLASH
  , C_LOGS_SECTION_MISSING
  , C_CHECKSUM_MISMATCH
  , C_COND_WRITE_NOT_READY
  , C_COND_WRITE_FAILED
  , C_FILE_OPEN
  , C_FILE_READ
  , C_LOCAL_LOG_STORE_WRITE
  , C_CAUGHT_UP
  , C_UNTIL_LSN_REACHED
  , C_WINDOW_END_REACHED
  , C_BYTE_LIMIT_REACHED
  , C_MALFORMED_RECORD
  , C_LOCAL_LOG_STORE_READ
  , C_SHADOW_DISABLED
  , C_SHADOW_UNCONFIGURED
  , C_SHADOW_FAILED
  , C_SHADOW_BUSY
  , C_SHADOW_LOADING
  , C_SHADOW_SKIP
  , C_VERSION_MISMATCH
  , C_SOURCE_STATE_MISMATCH
  , C_CONDITION_MISMATCH
  , C_MAINTENANCE_CLASH
  , C_WRITE_STREAM_UNKNOWN
  , C_WRITE_STREAM_BROKEN
  , C_WRITE_STREAM_IGNORED :: ErrorCode
pattern C_OK                    =   0
pattern C_NOTFOUND              =   1
pattern C_TIMEDOUT              =   2
pattern C_NOSEQUENCER           =   3
pattern C_CONNFAILED            =   4
pattern C_NOTCONN               =   5
pattern C_TOOBIG                =   6
pattern C_TOOMANY               =   7
pattern C_PREEMPTED             =   8
pattern C_NOBUFS                =   9
pattern C_NOMEM                 =  10
pattern C_INTERNAL              =  11
pattern C_SYSLIMIT              =  12
pattern C_TEMPLIMIT             =  13
pattern C_PERMLIMIT             =  14
pattern C_ACCESS                =  15
pattern C_ALREADY               =  16
pattern C_ISCONN                =  17
pattern C_UNREACHABLE           =  18
pattern C_UNROUTABLE            =  19
pattern C_BADMSG                =  20
pattern C_DISABLED              =  21
pattern C_EXISTS                =  22
pattern C_SHUTDOWN              =  23
pattern C_NOTINCONFIG           =  24
pattern C_PROTONOSUPPORT        =  25
pattern C_PROTO                 =  26
pattern C_PEER_CLOSED           =  27
pattern C_SEQNOBUFS             =  28
pattern C_WOULDBLOCK            =  29
pattern C_ABORTED               =  30
pattern C_INPROGRESS            =  31
pattern C_CANCELLED             =  32
pattern C_NOTSTORAGE            =  33
pattern C_AGAIN                 =  34
pattern C_PARTIAL               =  35
pattern C_GAP                   =  36
pattern C_TRUNCATED             =  37
pattern C_STALE                 =  38
pattern C_NOSPC                 =  39
pattern C_OVERLOADED            =  40
pattern C_PENDING               =  41
pattern C_PENDING_FULL          =  42
pattern C_FAILED                =  43
pattern C_SEQSYSLIMIT           =  44
pattern C_REBUILDING            =  45
pattern C_REDIRECTED            =  46
pattern C_RETRY                 =  47
pattern C_BADPAYLOAD            =  48
pattern C_NOSSLCONFIG           =  49
pattern C_NOTREADY              =  50
pattern C_DROPPED               =  51
pattern C_FORWARD               =  52
pattern C_NOTSUPPORTED          =  53
pattern C_NOTINSERVERCONFIG     =  54
pattern C_ISOLATED              =  55
pattern C_SSLREQUIRED           =  56
pattern C_CBREGISTERED          =  57
pattern C_LOW_ON_SPC            =  58
pattern C_PEER_UNAVAILABLE      =  59
pattern C_NOTSUPPORTEDLOG       =  60
pattern C_DATALOSS              =  61
pattern C_NEVER_CONNECTED       =  62
pattern C_NOTANODE              =  63
pattern C_IDLE                  =  64
pattern C_INVALID_PARAM         = 100
pattern C_INVALID_CLUSTER       = 101
pattern C_INVALID_CONFIG        = 102
pattern C_INVALID_THREAD        = 103
pattern C_INVALID_IP            = 104
pattern C_INVALID_OPERATION     = 105
pattern C_UNKNOWN_SETTING       = 106
pattern C_INVALID_SETTING_VALUE = 107
pattern C_UPTODATE              = 108
pattern C_EMPTY                 = 109
pattern C_DESTINATION_MISMATCH  = 110
pattern C_INVALID_ATTRIBUTES    = 111
pattern C_NOTEMPTY              = 112
pattern C_NOTDIR                = 113
pattern C_ID_CLASH              = 114
pattern C_LOGS_SECTION_MISSING  = 115
pattern C_CHECKSUM_MISMATCH     = 116
pattern C_COND_WRITE_NOT_READY  = 117
pattern C_COND_WRITE_FAILED     = 118
pattern C_FILE_OPEN             = 200
pattern C_FILE_READ             = 201
pattern C_LOCAL_LOG_STORE_WRITE = 300
pattern C_CAUGHT_UP             = 301
pattern C_UNTIL_LSN_REACHED     = 302
pattern C_WINDOW_END_REACHED    = 303
pattern C_BYTE_LIMIT_REACHED    = 304
pattern C_MALFORMED_RECORD      = 305
pattern C_LOCAL_LOG_STORE_READ  = 306
pattern C_SHADOW_DISABLED       = 401
pattern C_SHADOW_UNCONFIGURED   = 402
pattern C_SHADOW_FAILED         = 403
pattern C_SHADOW_BUSY           = 404
pattern C_SHADOW_LOADING        = 405
pattern C_SHADOW_SKIP           = 406
pattern C_VERSION_MISMATCH      = 500
pattern C_SOURCE_STATE_MISMATCH = 501
pattern C_CONDITION_MISMATCH    = 502
pattern C_MAINTENANCE_CLASH     = 600
pattern C_WRITE_STREAM_UNKNOWN  = 700
pattern C_WRITE_STREAM_BROKEN   = 701
pattern C_WRITE_STREAM_IGNORED  = 702

-------------------------------------------------------------------------------

-- | DebugLevel
type C_DBG_LEVEL = Word8

pattern C_DBG_CRITICAL :: C_DBG_LEVEL
pattern C_DBG_CRITICAL = (#const C_DBG_CRITICAL)

pattern C_DBG_ERROR :: C_DBG_LEVEL
pattern C_DBG_ERROR = (#const C_DBG_ERROR)

pattern C_DBG_WARNING :: C_DBG_LEVEL
pattern C_DBG_WARNING = (#const C_DBG_WARNING)

pattern C_DBG_NOTIFY :: C_DBG_LEVEL
pattern C_DBG_NOTIFY = (#const C_DBG_NOTIFY)

pattern C_DBG_INFO :: C_DBG_LEVEL
pattern C_DBG_INFO = (#const C_DBG_INFO)

pattern C_DBG_DEBUG :: C_DBG_LEVEL
pattern C_DBG_DEBUG = (#const C_DBG_DEBUG)

pattern C_DBG_SPEW :: C_DBG_LEVEL
pattern C_DBG_SPEW = (#const C_DBG_SPEW)

foreign import ccall unsafe "hs_logdevice.h set_dbg_level"
  c_set_dbg_level :: C_DBG_LEVEL -> IO ()

foreign import ccall unsafe "hs_logdevice.h dbg_use_fd"
  c_dbg_use_fd :: CInt -> IO CInt

-------------------------------------------------------------------------------

newtype FB_STATUS = FB_STATUS { unFB_STATUS :: CInt}
  deriving newtype (Eq, Num)

instance Show FB_STATUS where
  show FB_STATUS_STARTING = "FB_STATUS_STARTING"
  show FB_STATUS_ALIVE    = "FB_STATUS_ALIVE"
  show FB_STATUS_DEAD     = "FB_STATUS_DEAD"
  show FB_STATUS_STOPPING = "FB_STATUS_STOPPING"
  show FB_STATUS_STOPPED  = "FB_STATUS_STOPPED"
  show FB_STATUS_WARNING  = "FB_STATUS_WARNING"
  show _                  = "UNDEFINED_FB_STATUS"

pattern FB_STATUS_STARTING :: FB_STATUS
pattern FB_STATUS_STARTING = (#const static_cast<int>(fb_status::STARTING))

pattern FB_STATUS_ALIVE :: FB_STATUS
pattern FB_STATUS_ALIVE = (#const static_cast<int>(fb_status::ALIVE))

pattern FB_STATUS_DEAD :: FB_STATUS
pattern FB_STATUS_DEAD = (#const static_cast<int>(fb_status::DEAD))

pattern FB_STATUS_STOPPING :: FB_STATUS
pattern FB_STATUS_STOPPING = (#const static_cast<int>(fb_status::STOPPING))

pattern FB_STATUS_STOPPED :: FB_STATUS
pattern FB_STATUS_STOPPED = (#const static_cast<int>(fb_status::STOPPED))

pattern FB_STATUS_WARNING :: FB_STATUS
pattern FB_STATUS_WARNING = (#const static_cast<int>(fb_status::WARNING))
