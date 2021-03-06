{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE CPP #-}
module Network.HTTP.Conduit.ConnInfo
    ( ConnInfo
    , connClose
    , connSink
    , connSource
    , sslClientConn
    , socketConn
    , TLSCertificateRejectReason(..)
    , TLSCertificateUsage(..)
    , getSocket
#if DEBUG
    , printOpenSockets
    , requireAllSocketsClosed
    , clearSocketsList
#endif
    ) where

import Control.Exception (SomeException, throwIO, try)
import System.IO (Handle, hClose)

import Control.Monad.IO.Class (liftIO)

import Data.ByteString (ByteString)
import qualified Data.ByteString as S
import qualified Data.ByteString.Lazy as L

import Network (PortID(..))
import Network.Socket (Socket, sClose)
import Network.Socket.ByteString (recv, sendAll)
import qualified Network.Socket as NS
import Network.Socks5 (socksConnectWith, SocksConf)

import Network.TLS
import Network.TLS.Extra (ciphersuite_all)

import Data.Certificate.X509 (X509)

import Crypto.Random.AESCtr (makeSystem)

import qualified Data.Conduit as C

#if DEBUG
import qualified Data.IntMap as IntMap
import qualified Data.IORef as I
import System.IO.Unsafe (unsafePerformIO)
#endif

data ConnInfo = ConnInfo
    { connRead :: IO ByteString
    , connWrite :: ByteString -> IO ()
    , connClose :: IO ()
    }

connSink :: C.MonadResource m => ConnInfo -> C.Sink ByteString m ()
connSink ConnInfo { connWrite = write } =
    C.NeedInput push close
  where
    push bss = C.PipeM
        (liftIO (write bss) >> return (C.NeedInput push close))
        (return ())
    close = return ()

connSource :: C.MonadResource m => ConnInfo -> C.Source m ByteString
connSource ConnInfo { connRead = read' } =
    src
  where
    src = C.PipeM pull close
    pull = do
        bs <- liftIO read'
        if S.null bs
            then return (return ())
            else return $ C.HaveOutput src close bs
    close = return ()

#if DEBUG
allOpenSockets :: I.IORef (Int, IntMap.IntMap String)
allOpenSockets = unsafePerformIO $ I.newIORef (0, IntMap.empty)

addSocket :: String -> IO Int
addSocket desc = I.atomicModifyIORef allOpenSockets $ \(next, m) ->
    ((next + 1, IntMap.insert next desc m), next)

removeSocket :: Int -> IO ()
removeSocket i = I.atomicModifyIORef allOpenSockets $ \(next, m) ->
    ((next, IntMap.delete i m), ())

printOpenSockets :: IO ()
printOpenSockets = do
    (_, m) <- I.readIORef allOpenSockets
    putStrLn "\n\nOpen sockets:"
    if IntMap.null m
        then putStrLn "** No open sockets!"
        else mapM_ putStrLn $ IntMap.elems m

requireAllSocketsClosed :: IO ()
requireAllSocketsClosed = do
    (_, m) <- I.readIORef allOpenSockets
    if IntMap.null m
        then return ()
        else error $ unlines
            $ "requireAllSocketsClosed: there are open sockets"
            : IntMap.elems m

clearSocketsList :: IO ()
clearSocketsList = I.writeIORef allOpenSockets (0, IntMap.empty)
#endif

socketConn :: String -> Socket -> IO ConnInfo
socketConn _desc sock = do
#if DEBUG
    i <- addSocket _desc
#endif
    return ConnInfo
        { connRead  = recv sock 4096
        , connWrite = sendAll sock
        , connClose = do
#if DEBUG
            removeSocket i
#endif
            sClose sock
        }

sslClientConn :: String -> ([X509] -> IO TLSCertificateUsage) -> Handle -> IO ConnInfo
sslClientConn _desc onCerts h = do
#if DEBUG
    i <- addSocket _desc
#endif
    let tcp = defaultParams
            { pConnectVersion = TLS10
            , pAllowedVersions = [ TLS10, TLS11, TLS12 ]
            , pCiphers = ciphersuite_all
            , onCertificatesRecv = onCerts
            }
    gen <- makeSystem
    istate <- client tcp gen h
    handshake istate
    return ConnInfo
        { connRead = recvD istate
        , connWrite = sendData istate . L.fromChunks . (:[])
        , connClose = do
#if DEBUG
            removeSocket i
#endif
            bye istate
            hClose h
        }
  where
    recvD istate = do
        x <- recvData istate
        if S.null x
            then recvD istate
            else return x

getSocket :: String -> Int -> Maybe SocksConf -> IO NS.Socket
getSocket host' port' (Just socksConf) = do
    socksConnectWith socksConf host' (PortNumber $ fromIntegral port')
getSocket host' port' Nothing = do
    let hints = NS.defaultHints {
                          NS.addrFlags = [NS.AI_ADDRCONFIG]
                        , NS.addrSocketType = NS.Stream
                        }
    (addr:_) <- NS.getAddrInfo (Just hints) (Just host') (Just $ show port')
    sock <- NS.socket (NS.addrFamily addr) (NS.addrSocketType addr)
                      (NS.addrProtocol addr)
    ee <- try' $ NS.connect sock (NS.addrAddress addr)
    case ee of
        Left e -> NS.sClose sock >> throwIO e
        Right () -> return sock
  where
    try' :: IO a -> IO (Either SomeException a)
    try' = try
