{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

-- |
-- Module: Chainweb.Pact.PactService
-- Copyright: Copyright © 2018,2019,2020 Kadena LLC.
-- License: See LICENSE file
-- Maintainers: Lars Kuhtz, Emily Pillmore, Stuart Popejoy
-- Stability: experimental
--
-- Pact service for Chainweb
--
module Chainweb.Pact.PactService
    ( initialPayloadState
    , execNewBlock
    , execValidateBlock
    , execTransactions
    , execLocal
    , execLookupPactTxs
    , execPreInsertCheckReq
    , execBlockTxHistory
    , execHistoricalLookup
    , execSyncToBlock
    , runPactService
    , withPactService
    , execNewGenesisBlock
    , getGasModel
    ) where

import Control.Concurrent.Async
import Control.Concurrent.MVar
import Control.Exception (SomeAsyncException)
import Control.Lens
import Control.Monad
import Control.Monad.Catch
import Control.Monad.Reader
import Control.Monad.State.Strict

import qualified Data.Aeson as A
import Data.Default (def)
import qualified Data.DList as DL
import Data.Either
import Data.Word (Word64)
import Data.Maybe (fromMaybe)
import Data.Foldable (toList)
import qualified Data.HashMap.Strict as HM
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.Text (Text)
import qualified Data.Text as T
import Data.Vector (Vector)
import qualified Data.Vector as V

import System.IO

import Prelude hiding (lookup)

import qualified Pact.Gas as P
import Pact.Gas.Table
import qualified Pact.Interpreter as P
import qualified Pact.Types.ChainMeta as P
import qualified Pact.Types.Command as P
import qualified Pact.Types.Hash as P
import qualified Pact.Types.Logger as P
import qualified Pact.Types.Runtime as P
import qualified Pact.Types.SPV as P
import qualified Pact.Types.Pretty as P

import Chainweb.BlockHash
import Chainweb.BlockHeader
import Chainweb.BlockHeaderDB
import Chainweb.BlockHeight
import Chainweb.ChainId
import Chainweb.Logger
import Chainweb.Mempool.Mempool as Mempool
import Chainweb.Miner.Pact
import Chainweb.Pact.Backend.RelationalCheckpointer (withProdRelationalCheckpointer)
import Chainweb.Pact.Backend.Types
import Chainweb.Pact.PactService.ExecBlock
import Chainweb.Pact.PactService.Checkpointer
import Chainweb.Pact.Service.PactQueue (PactQueue, getNextRequest)
import Chainweb.Pact.Service.Types
import Chainweb.Pact.TransactionExec
import Chainweb.Pact.Types
import Chainweb.Pact.Validations
import Chainweb.Payload
import Chainweb.Payload.PayloadStore
import Chainweb.Time
import Chainweb.Transaction
import Chainweb.TreeDB (lookupM, seekAncestor)
import Chainweb.Utils hiding (check)
import Chainweb.Version
import Chainweb.Version.Guards
import Data.LogMessage
import Utils.Logging.Trace

import Dyna (Vec)
import Dyna qualified
import Control.Monad.Primitive (PrimState)
import Data.Primitive (Array)

runPactService
    :: Logger logger
    => CanReadablePayloadCas tbl
    => ChainwebVersion
    -> ChainId
    -> logger
    -> PactQueue
    -> MemPoolAccess
    -> BlockHeaderDb
    -> PayloadDb tbl
    -> SQLiteEnv
    -> PactServiceConfig
    -> IO ()
runPactService ver cid chainwebLogger reqQ mempoolAccess bhDb pdb sqlenv config =
    void $ withPactService ver cid chainwebLogger bhDb pdb sqlenv config $ do
        initialPayloadState chainwebLogger mempoolAccess ver cid
        serviceRequests (logFunction chainwebLogger) mempoolAccess reqQ

withPactService
    :: Logger logger
    => CanReadablePayloadCas tbl
    => ChainwebVersion
    -> ChainId
    -> logger
    -> BlockHeaderDb
    -> PayloadDb tbl
    -> SQLiteEnv
    -> PactServiceConfig
    -> PactServiceM tbl a
    -> IO (T2 a PactServiceState)
withPactService ver cid chainwebLogger bhDb pdb sqlenv config act =
    withProdRelationalCheckpointer checkpointerLogger initialBlockState sqlenv cplogger ver cid $ \checkpointEnv -> do
        let !rs = readRewards
            !initialParentHeader = ParentHeader $ genesisBlockHeader ver cid
            !pse = PactServiceEnv
                    { _psMempoolAccess = Nothing
                    , _psCheckpointEnv = checkpointEnv
                    , _psPdb = pdb
                    , _psBlockHeaderDb = bhDb
                    , _psGasModel = getGasModel
                    , _psMinerRewards = rs
                    , _psReorgLimit = _pactReorgLimit config
                    , _psLocalRewindDepthLimit = _pactLocalRewindDepthLimit config
                    , _psOnFatalError = defaultOnFatalError (logFunctionText chainwebLogger)
                    , _psVersion = ver
                    , _psValidateHashesOnReplay = _pactRevalidate config
                    , _psAllowReadsInLocal = _pactAllowReadsInLocal config
                    , _psIsBatch = False
                    , _psCheckpointerDepth = 0
                    , _psTraceLogger = logFunction chainwebLogger
                    , _psLogger = pactLogger
                    , _psGasLogger = gasLogger <$ guard (_pactLogGas config)
                    , _psLoggers = loggers
                    , _psBlockGasLimit = _pactBlockGasLimit config
                    , _psChainId = cid
                    }
            !pst = PactServiceState Nothing mempty initialParentHeader P.noSPVSupport
        runPactServiceM pst pse $ do

            -- If the latest header that is stored in the checkpointer was on an
            -- orphaned fork, there is no way to recover it in the call of
            -- 'initalPayloadState.readContracts'. We therefore rewind to the latest
            -- avaliable header in the block header database.
            --
            exitOnRewindLimitExceeded $ initializeLatestBlock (_pactUnlimitedInitialRewind config)
            act
  where
    initialBlockState = initBlockState (_pactModuleCacheLimit config) $ genesisHeight ver cid
    loggers = pactLoggers chainwebLogger
    cplogger = P.newLogger loggers $ P.LogName "Checkpointer"
    pactLogger = P.newLogger loggers $ P.LogName "PactService"
    gasLogger = P.newLogger loggers $ P.LogName "GasLogs"

    checkpointerLogger = addLabel ("sub-component", "checkpointer") chainwebLogger

initializeLatestBlock :: CanReadablePayloadCas tbl => Bool -> PactServiceM tbl ()
initializeLatestBlock unlimitedRewind = findLatestValidBlock >>= \case
    Nothing -> return ()
    Just b -> withBatch $ rewindTo initialRewindLimit (Just $ ParentHeader b)
  where
    initialRewindLimit = RewindLimit 1000 <$ guard (not unlimitedRewind)

initialPayloadState
    :: Logger logger
    => CanReadablePayloadCas tbl
    => logger
    -> MemPoolAccess
    -> ChainwebVersion
    -> ChainId
    -> PactServiceM tbl ()
initialPayloadState logger mpa v cid
    | v ^. versionCheats . disablePact = pure ()
    | otherwise = initializeCoinContract logger mpa v cid $
        v ^?! versionGenesis . genesisBlockPayload . onChain cid

initializeCoinContract
    :: forall tbl logger. (CanReadablePayloadCas tbl, Logger logger)
    => logger
    -> MemPoolAccess
    -> ChainwebVersion
    -> ChainId
    -> PayloadWithOutputs
    -> PactServiceM tbl ()
initializeCoinContract _logger memPoolAccess v cid pwo = do
    cp <- getCheckpointer
    latestBlock <- liftIO $ _cpGetLatestBlock cp
    case latestBlock of
      Nothing -> do
        logWarn "initializeCoinContract: Checkpointer returned no latest block. Starting from genesis."
        validateGenesis
      Just (_currentBlockHeight, currentBlockHash) -> do
        -- We check the block hash because it's more principled and
        -- we don't have to compute it, so the comparison is still relatively
        -- cheap. We could also check the height but that would be redundant.
        if currentBlockHash /= genesisHash
        then do
          readContracts
        else do
          logWarn "initializeCoinContract: Starting from genesis."
          validateGenesis
  where
    validateGenesis = void $!
        execValidateBlock memPoolAccess genesisHeader inputPayloadData

    genesisHash :: BlockHash
    genesisHash = _blockHash genesisHeader

    inputPayloadData :: PayloadData
    inputPayloadData = payloadWithOutputsToPayloadData pwo

    genesisHeader :: BlockHeader
    genesisHeader = genesisBlockHeader v cid

    readContracts = withDiscardedBatch $ do
      parent <- syncParentHeader "initializeCoinContract.readContracts"
      withCheckpointerRewind Nothing (Just parent) "initializeCoinContract.readContracts" $ \(PactDbEnv' pdbenv) -> do
        PactServiceEnv{..} <- ask
        pd <- getTxContext def
        !mc <- liftIO $ readInitModules _psLogger pdbenv pd
        updateInitCache mc
        return $! Discard ()

-- | Lookup a block header.
--
-- The block header is expected to be either in the block header database or to
-- be the the currently stored '_psParentHeader'. The latter addresses the case
-- when a block has already been validate with 'execValidateBlock' but isn't (yet)
-- available in the block header database. If that's the case two things can
-- happen:
--
-- 1. the header becomes available before the next 'execValidateBlock' call, or
-- 2. the header gets orphaned and the next 'execValidateBlock' call would cause
--    a rewind to an ancestor, which is available in the db.
--
lookupBlockHeader :: BlockHash -> Text -> PactServiceM tbl BlockHeader
lookupBlockHeader bhash ctx = do
    ParentHeader cur <- use psParentHeader
    if (bhash == _blockHash cur)
      then return cur
      else do
        bhdb <- view psBlockHeaderDb
        liftIO $! lookupM bhdb bhash `catchAllSynchronous` \e ->
            throwM $ BlockHeaderLookupFailure $
                "failed lookup of parent header in " <> ctx <> ": " <> sshow e

-- | Loop forever, serving Pact execution requests and reponses from the queues
serviceRequests
    :: CanReadablePayloadCas tbl
    => LogFunction
    -> MemPoolAccess
    -> PactQueue
    -> PactServiceM tbl ()
serviceRequests logFn memPoolAccess reqQ = do
    logInfo "Starting service"
    go `finally` logInfo "Stopping service"
  where
    go = do
        logDebug "serviceRequests: wait"
        msg <- liftIO $ getNextRequest reqQ
        logDebug $ "serviceRequests: " <> sshow msg
        case msg of
            CloseMsg -> return ()
            LocalMsg (LocalReq localRequest preflight sigVerify rewindDepth localResultVar)  -> do
                trace logFn "Chainweb.Pact.PactService.execLocal" () 0 $
                    tryOne "execLocal" localResultVar $
                        execLocal localRequest preflight sigVerify rewindDepth
                go
            NewBlockMsg NewBlockReq {..} -> do
                trace logFn "Chainweb.Pact.PactService.execNewBlock"
                    (_parentHeader _newBlockHeader) 1 $
                    tryOne "execNewBlock" _newResultVar $
                        execNewBlock memPoolAccess _newBlockHeader _newMiner
                go
            ValidateBlockMsg ValidateBlockReq {..} -> do
                tryOne "execValidateBlock" _valResultVar $
                  fmap fst $ trace' logFn "Chainweb.Pact.PactService.execValidateBlock"
                    _valBlockHeader
                    (\(_, g) -> fromIntegral g)
                    (execValidateBlock memPoolAccess _valBlockHeader _valPayloadData)
                go
            LookupPactTxsMsg (LookupPactTxsReq restorePoint confDepth txHashes resultVar) -> do
                trace logFn "Chainweb.Pact.PactService.execLookupPactTxs" ()
                    (length txHashes) $
                    tryOne "execLookupPactTxs" resultVar $
                        execLookupPactTxs restorePoint confDepth txHashes
                go
            PreInsertCheckMsg (PreInsertCheckReq txs resultVar) -> do
                trace logFn "Chainweb.Pact.PactService.execPreInsertCheckReq" ()
                    (length txs) $
                    tryOne "execPreInsertCheckReq" resultVar $
                        V.map (() <$) <$> execPreInsertCheckReq txs
                go
            BlockTxHistoryMsg (BlockTxHistoryReq bh d resultVar) -> do
                trace logFn "Chainweb.Pact.PactService.execBlockTxHistory" bh 1 $
                    tryOne "execBlockTxHistory" resultVar $
                        execBlockTxHistory bh d
                go
            HistoricalLookupMsg (HistoricalLookupReq bh d k resultVar) -> do
                trace logFn "Chainweb.Pact.PactService.execHistoricalLookup" bh 1 $
                    tryOne "execHistoricalLookup" resultVar $
                        execHistoricalLookup bh d k
                go
            SyncToBlockMsg SyncToBlockReq {..} -> do
                trace logFn "Chainweb.Pact.PactService.execSyncToBlock" _syncToBlockHeader 1 $
                    tryOne "syncToBlockBlock" _syncToResultVar $
                        execSyncToBlock _syncToBlockHeader
                go

    toPactInternalError e = Left $ PactInternalError $ T.pack $ show e

    tryOne
        :: String
        -> MVar (Either PactException a)
        -> PactServiceM tbl a
        -> PactServiceM tbl ()
    tryOne which mvar = tryOne' which mvar Right

    tryOne'
        :: String
        -> MVar (Either PactException b)
        -> (a -> Either PactException b)
        -> PactServiceM tbl a
        -> PactServiceM tbl ()
    tryOne' which mvar post m =
        (evalPactOnThread (post <$> m) >>= (liftIO . putMVar mvar))
        `catches`
            [ Handler $ \(e :: SomeAsyncException) -> do
                logWarn $ mconcat
                    [ "Received asynchronous exception running pact service ("
                    , which
                    , "): "
                    , show e
                    ]
                liftIO $ do
                    void $ tryPutMVar mvar $! toPactInternalError e
                    throwM e
            , Handler $ \(e :: SomeException) -> do
                logError $ mconcat
                    [ "Received exception running pact service ("
                    , which
                    , "): "
                    , show e
                    ]
                liftIO $ do
                    void $ tryPutMVar mvar $! toPactInternalError e
           ]
      where
        -- Pact turns AsyncExceptions into textual exceptions within
        -- PactInternalError. So there is no easy way for us to distinguish
        -- whether an exception originates from within pact or from the outside.
        --
        -- A common strategy to deal with this is to run the computation (pact)
        -- on a "hidden" internal thread. Lifting `forkIO` into a state
        -- monad is generally not thread-safe. It is fine to do here, since
        -- there is no concurrency. We use a thread here only to shield the
        -- computation from external exceptions.
        --
        -- This solution isn't bullet-proof and only meant as a temporary fix. A
        -- proper solution is to fix pact, to handle asynchronous exceptions
        -- gracefully.
        --
        -- No mask is needed here. Asynchronous exceptions are handled
        -- by the outer handlers and cause an abort. So no state is lost.
        --
        evalPactOnThread :: PactServiceM tbl a -> PactServiceM tbl a
        evalPactOnThread act = do
            e <- ask
            s <- get
            T2 r s' <- liftIO $
                withAsync (runPactServiceM s e act) wait
            put $! s'
            return $! r

-- | Performs a dry run of PactExecution's `buyGas` function for transactions being validated.
--
attemptBuyGas
    :: Miner
    -> PactDbEnv'
    -> Vector (Either InsertError ChainwebTransaction)
    -> PactServiceM tbl (Vector (Either InsertError ChainwebTransaction))
attemptBuyGas miner (PactDbEnv' dbEnv) txs = do
        mc <- getInitCache
        l <- P.newLogger <$> view psLoggers <*> pure "attemptBuyGas"
        V.fromList . toList . sfst <$> V.foldM (f l) (T2 mempty mc) txs
  where
    f l (T2 dl mcache) cmd = do
        T2 mcache' !res <- runBuyGas l dbEnv mcache cmd
        pure $! T2 (DL.snoc dl res) mcache'

    createGasEnv
        :: P.Logger
        -> P.PactDbEnv db
        -> P.Command (P.Payload P.PublicMeta P.ParsedCode)
        -> P.GasPrice
        -> P.Gas
        -> PactServiceM tbl (TransactionEnv db)
    createGasEnv l db cmd gp gl = do
        pd <- getTxContext (publicMetaOf cmd)
        spv <- use psSpvSupport
        let ec = P.mkExecutionConfig $
              [ P.FlagDisableModuleInstall
              , P.FlagDisableHistoryInTransactionalMode ] ++
              disableReturnRTC (ctxVersion pd) (ctxChainId pd) (ctxCurrentBlockHeight pd)
        return $! TransactionEnv P.Transactional db l Nothing (ctxToPublicData pd) spv nid gp rk gl ec
      where
        !nid = networkIdOf cmd
        !rk = P.cmdToRequestKey cmd

    runBuyGas
        :: P.Logger
        -> P.PactDbEnv a
        -> ModuleCache
        -> Either InsertError ChainwebTransaction
        -> PactServiceM tbl (T2 ModuleCache (Either InsertError ChainwebTransaction))
    runBuyGas _l _db mcache l@Left {} = return (T2 mcache l)
    runBuyGas l db mcache (Right tx) = do
        let cmd = payloadObj <$> tx
            gasPrice = view cmdGasPrice cmd
            gasLimit = fromIntegral $ view cmdGasLimit cmd
            txst = TransactionState
                { _txCache = mcache
                , _txLogs = mempty
                , _txGasUsed = 0
                , _txGasId = Nothing
                , _txGasModel = P._geGasModel P.freeGasEnv
                , _txWarnings = mempty
                }

        buyGasEnv <- createGasEnv l db cmd gasPrice gasLimit

        cr <- liftIO
          $! catchesPactError l CensorsUnexpectedError
          $! execTransactionM buyGasEnv txst
          $! buyGas False cmd miner

        case cr of
            Left err -> return (T2 mcache (Left (InsertErrorBuyGas (T.pack $ show err))))
            Right t -> return (T2 (_txCache t) (Right tx))

-- | Note: The BlockHeader param here is the PARENT HEADER of the new
-- block-to-be
--
execNewBlock
    :: CanReadablePayloadCas tbl
    => MemPoolAccess
    -> ParentHeader
    -> Miner
    -> PactServiceM tbl PayloadWithOutputs
execNewBlock mpAccess parent miner = do
    updateMempool
    withDiscardedBatch $ do
      withCheckpointerRewind newblockRewindLimit (Just parent) "execNewBlock" doNewBlock
  where
    handleTimeout :: TxTimeout -> PactServiceM cas a
    handleTimeout (TxTimeout h) = do
      logError $ "execNewBlock: timed out on " <> sshow h
      liftIO $ mpaBadlistTx mpAccess (V.singleton h)
      throwM (TxTimeout h)

    -- This is intended to mitigate mining attempts during replay.
    -- In theory we shouldn't need to rewind much ever, but values
    -- less than this are failing in PactReplay test.
    newblockRewindLimit = Just $ RewindLimit 8

    getBlockTxs :: BlockFill -> PactServiceM tbl (Vector ChainwebTransaction)
    getBlockTxs bfState = do
      cp <- getCheckpointer
      psEnv <- ask
      logger <- view psLogger
      let validate bhi _bha txs = do

            let parentTime = ParentCreationTime $ _blockCreationTime $ _parentHeader parent
            results <- do
                let v = _chainwebVersion psEnv
                    cid = _chainId psEnv
                validateChainwebTxs logger v cid cp parentTime bhi txs return

            V.forM results $ \case
                Right _ -> return True
                Left _e -> return False

      liftIO $!
        mpaGetBlock mpAccess bfState validate (pHeight + 1) pHash (_parentHeader parent)

    doNewBlock pdbenv = do
        logInfo $ "execNewBlock: "
                <> " (parent height = " <> sshow pHeight <> ")"
                <> " (parent hash = " <> sshow pHash <> ")"

        blockGasLimit <- view psBlockGasLimit
        let initState = BlockFill blockGasLimit mempty 0

        let
            txTimeHeadroomFactor :: Double
            txTimeHeadroomFactor = 5
            -- 2.5 microseconds per unit gas
            txTimeLimit :: Micros
            txTimeLimit = round $ (2.5 * txTimeHeadroomFactor) * fromIntegral blockGasLimit

        -- Heuristic: limit fetches to count of 1000-gas txs in block.
        let fetchLimit = fromIntegral $ blockGasLimit `div` 1000

        newTrans <- getBlockTxs initState

        -- NEW BLOCK COINBASE: Reject bad coinbase, always use precompilation
        Transactions pairs cb <- execTransactions False miner newTrans
          (EnforceCoinbaseFailure True)
          (CoinbaseUsePrecompiled True)
          pdbenv
          Nothing
          (Just txTimeLimit) `catch` handleTimeout

        successes <- liftIO $ Dyna.new @_ @Array @_ @(ChainwebTransaction, P.CommandResult [P.TxLog A.Value])
        failures <- liftIO $ Dyna.new @_ @Array @_ @GasPurchaseFailure
        _ <- refill fetchLimit txTimeLimit pdbenv successes failures =<<
          foldM (splitResults successes failures) (incCount initState) pairs

        liftIO $ do
          txHashes <- Dyna.toLiftedVectorWith (\_ failure -> pure (gasPurchaseFailureHash failure)) failures
          mpaBadlistTx mpAccess txHashes

        !pwo <- liftIO $ do
          txs <- Dyna.toLiftedVector successes
          pure (toPayloadWithOutputs miner (Transactions txs cb))
        return $! Discard pwo

    refill :: Word64 -> Micros -> PactDbEnv' -> GrowableVec (ChainwebTransaction, P.CommandResult [P.TxLog A.Value]) -> GrowableVec GasPurchaseFailure -> BlockFill -> PactServiceM tbl BlockFill
    refill fetchLimit txTimeLimit pdbenv successes failures = go
      where
        go :: BlockFill -> PactServiceM tbl BlockFill
        go unchanged@bfState = do

          case unchanged of
            BlockFill g _ c -> do
              (goodLength, badLength) <- liftIO $ (,) <$> Dyna.length successes <*> Dyna.length failures
              logDebug $ "Block fill: count=" <> sshow c
                <> ", gaslimit=" <> sshow g <> ", good="
                <> sshow goodLength <> ", bad=" <> sshow badLength

          -- LOOP INVARIANT: limit absolute recursion count
          when (_bfCount bfState > fetchLimit) $
            throwM $ MempoolFillFailure $ "Refill fetch limit exceeded (" <> sshow fetchLimit <> ")"

          when (_bfGasLimit bfState < 0) $
            throwM $ MempoolFillFailure $ "Internal error, negative gas limit: " <> sshow bfState

          if _bfGasLimit bfState == 0 then pure unchanged else do

            newTrans <- getBlockTxs bfState
            if V.null newTrans then pure unchanged else do

              pairs <- execTransactionsOnly miner newTrans pdbenv
                (Just txTimeLimit) `catch` handleTimeout

              (oldPairsLength, oldFailsLength) <- liftIO $ (,)
                <$> Dyna.length successes
                <*> Dyna.length failures

              newState <- foldM (splitResults successes failures) unchanged pairs

              -- LOOP INVARIANT: gas must not increase
              when (_bfGasLimit newState > _bfGasLimit bfState) $
                throwM $ MempoolFillFailure $ "Gas must not increase: " <> sshow (bfState,newState)

              (newPairsLength, newFailsLength) <- liftIO $ (,)
                <$> Dyna.length successes
                <*> Dyna.length failures
              let newSuccessCount = newPairsLength - oldPairsLength
              let newFailCount = newFailsLength - oldFailsLength

              -- LOOP INVARIANT: gas must decrease ...
              if (_bfGasLimit newState < _bfGasLimit bfState)
                  -- ... OR only non-zero failures were returned.
                 || (newSuccessCount == 0  && newFailCount > 0)
                  then go (incCount newState)
                  else throwM $ MempoolFillFailure $ "Invariant failure: " <>
                       sshow (bfState,newState,V.length newTrans
                             ,newPairsLength,newFailsLength)

    incCount :: BlockFill -> BlockFill
    incCount b = over bfCount succ b

    splitResults success fails (BlockFill g rks i) (t,r) = case r of
      Right cr -> do
        !rks' <- enforceUnique rks (requestKeyToTransactionHash $ P._crReqKey cr)
        -- Decrement actual gas used from block limit
        let !g' = g - fromIntegral (P._crGas cr)
        liftIO $ Dyna.push success (t, cr)
        return $ BlockFill g' rks' i
      Left f -> do
        !rks' <- enforceUnique rks (gasPurchaseFailureHash f)
        -- Gas buy failure adds failed request key to fail list only
        liftIO $ Dyna.push fails f
        return $ BlockFill g rks' i

    enforceUnique rks rk
      | S.member rk rks =
        throwM $ MempoolFillFailure $ "Duplicate transaction: " <> sshow rk
      | otherwise = return $ S.insert rk rks

    pHeight = _blockHeight $ _parentHeader parent
    pHash = _blockHash $ _parentHeader parent

    updateMempool = liftIO $ do
      mpaProcessFork mpAccess $ _parentHeader parent
      mpaSetLastHeader mpAccess $ _parentHeader parent


type GrowableVec = Vec Array (PrimState IO)

-- | only for use in generating genesis blocks in tools
--
execNewGenesisBlock
    :: CanReadablePayloadCas tbl
    => Miner
    -> Vector ChainwebTransaction
    -> PactServiceM tbl PayloadWithOutputs
execNewGenesisBlock miner newTrans = withDiscardedBatch $
    withCheckpointerRewind Nothing Nothing "execNewGenesisBlock" $ \pdbenv -> do

        -- NEW GENESIS COINBASE: Reject bad coinbase, use date rule for precompilation
        results <- execTransactions True miner newTrans
                   (EnforceCoinbaseFailure True)
                   (CoinbaseUsePrecompiled False) pdbenv Nothing Nothing
                   >>= throwOnGasFailure
        return $! Discard (toPayloadWithOutputs miner results)

execLocal
    :: CanReadablePayloadCas tbl
    => ChainwebTransaction
    -> Maybe LocalPreflightSimulation
      -- ^ preflight flag
    -> Maybe LocalSignatureVerification
      -- ^ turn off signature verification checks?
    -> Maybe RewindDepth
      -- ^ rewind depth
    -> PactServiceM tbl LocalResult
execLocal cwtx preflight sigVerify rdepth = withDiscardedBatch $ do
    parent <- syncParentHeader "execLocal"

    PactServiceEnv{..} <- ask

    let !cmd = payloadObj <$> cwtx
        !pm = publicMetaOf cmd

    mc <- getInitCache
    ctx <- getTxContext pm
    spv <- use psSpvSupport

    -- when no depth is defined, treat
    -- withCheckpointerRewind as withCurrentCheckpointer
    -- (i.e. setting rewind to 0).
    let rewindDepth = fromMaybe (RewindDepth 0) rdepth

    when (_rewindDepth rewindDepth > _rewindLimit _psLocalRewindDepthLimit) $ do
        throwM $ LocalRewindLimitExceeded _psLocalRewindDepthLimit rewindDepth

    let parentBlockHeader = _parentHeader parent

    -- we fail if the requested depth is bigger than the current parent block height
    -- because we can't go after the genesis block
    when (_rewindDepth rewindDepth > getBlockHeight (_blockHeight parentBlockHeader)) $ throwM LocalRewindGenesisExceeded

    let ancestorRank = fromIntegral $ (getBlockHeight $ _blockHeight parentBlockHeader) - _rewindDepth rewindDepth
    ancestor <- liftIO $ seekAncestor _psBlockHeaderDb parentBlockHeader ancestorRank

    rewindHeader <- case ancestor of
        Just a -> pure $ Just $ ParentHeader a
        Nothing -> throwM $ BlockHeaderLookupFailure $
            "failed seekAncestor of parent header with ancestorRank " <> sshow ancestorRank

    let execConfig = P.mkExecutionConfig $
            [ P.FlagAllowReadInLocal | _psAllowReadsInLocal ] ++
            enablePactEvents' (ctxVersion ctx) (ctxChainId ctx) (ctxCurrentBlockHeight ctx) ++
            enforceKeysetFormats' (ctxVersion ctx) (ctxChainId ctx) (ctxCurrentBlockHeight ctx) ++
            disableReturnRTC (ctxVersion ctx) (ctxChainId ctx) (ctxCurrentBlockHeight ctx)
        logger = P.newLogger _psLoggers "execLocal"
        initialGas = initialGasOf $ P._cmdPayload cwtx

    -- In this case the rewind limit is the same as rewind depth
    let rewindLimit = RewindLimit $ _rewindDepth rewindDepth
    withCheckpointerRewind (Just rewindLimit) rewindHeader "execLocal" $
      \(PactDbEnv' pdbenv) -> do
        --
        -- if the ?preflight query parameter is set to True, we run the `applyCmd` workflow
        -- otherwise, we prefer the old (default) behavior. When no preflight flag is
        -- specified, we run the old behavior. When it is set to true, we also do metadata
        -- validations.
        --
        r <- case preflight of
          Just PreflightSimulation -> do
            assertLocalMetadata cmd ctx sigVerify >>= \case
              Right{} -> do
                T3 cr _mc warns <- liftIO $ applyCmd
                  _psVersion logger _psGasLogger pdbenv
                  noMiner chainweb213GasModel ctx spv cmd
                  initialGas mc ApplyLocal

                let cr' = toHashCommandResult cr
                    warns' = P.renderCompactText <$> toList warns
                pure $ LocalResultWithWarns cr' warns'
              Left e -> pure $ MetadataValidationFailure e
          _ ->  liftIO $ do
            cr <- applyLocal
              logger _psGasLogger pdbenv
              chainweb213GasModel ctx spv
              cwtx mc execConfig

            let cr' = toHashCommandResult cr
            pure $ LocalResultLegacy cr'

        return $ Discard r

execSyncToBlock
    :: CanReadablePayloadCas tbl
    => BlockHeader
    -> PactServiceM tbl ()
execSyncToBlock hdr = rewindToIncremental Nothing (Just $ ParentHeader hdr)

-- | Validate a mined block. Execute the transactions in Pact again as
-- validation. Note: The BlockHeader here is the header of the block being
-- validated.
--
execValidateBlock
    :: CanReadablePayloadCas tbl
    => MemPoolAccess
    -> BlockHeader
    -> PayloadData
    -> PactServiceM tbl (PayloadWithOutputs, P.Gas)
execValidateBlock memPoolAccess currHeader plData = do
    -- The parent block header must be available in the block header database
    target <- getTarget
    psEnv <- ask
    let reorgLimit = view psReorgLimit psEnv
    T2 miner transactions <- exitOnRewindLimitExceeded $ withBatch $ do
        withCheckpointerRewind (Just reorgLimit) target "execValidateBlock" $ \pdbenv -> do
            !result <- execBlock currHeader plData pdbenv
            return $! Save currHeader result
    !result <- either throwM return $
        validateHashes currHeader plData miner transactions

    -- update mempool
    --
    -- Using the parent isn't optimal, since it doesn't delete the txs of
    -- `currHeader` from the set of pending tx. The reason for this is that the
    -- implementation 'mpaProcessFork' uses the chain database and at this point
    -- 'currHeader' is generally not yet available in the database. It would be
    -- possible to extract the txs from the result and remove them from the set
    -- of pending txs. However, that would add extra complexity and at little
    -- gain.
    --
    case target of
        Nothing -> return ()
        Just (ParentHeader p) -> liftIO $ do
            mpaProcessFork memPoolAccess p
            mpaSetLastHeader memPoolAccess p

    let !totalGasUsed = sumOf (folded . to P._crGas) transactions
    return (result, totalGasUsed)
  where
    getTarget
        | isGenesisBlockHeader currHeader = return Nothing
        | otherwise = Just . ParentHeader
            <$> lookupBlockHeader (_blockParent currHeader) "execValidateBlock"
                -- It is up to the user of pact service to guaranteed that this
                -- succeeds. If this fails it usually means that the block
                -- header database is corrupted.

execBlockTxHistory :: BlockHeader -> Domain' -> PactServiceM tbl BlockTxHistory
execBlockTxHistory bh (Domain' d) = do
  !cp <- getCheckpointer
  liftIO $ _cpGetBlockHistory cp bh d

execHistoricalLookup :: BlockHeader -> Domain' -> P.RowKey -> PactServiceM tbl (Maybe (P.TxLog A.Value))
execHistoricalLookup bh (Domain' d) k = do
  !cp <- getCheckpointer
  liftIO $ _cpGetHistoricalLookup cp bh d k

execPreInsertCheckReq
    :: CanReadablePayloadCas tbl
    => Vector ChainwebTransaction
    -> PactServiceM tbl (Vector (Either Mempool.InsertError ChainwebTransaction))
execPreInsertCheckReq txs = withDiscardedBatch $ do
    parent <- use psParentHeader
    let currHeight = succ $ _blockHeight $ _parentHeader parent
    psEnv <- ask
    psState <- get
    let parentTime = ParentCreationTime $ _blockCreationTime $ _parentHeader parent
    cp <- getCheckpointer
    logger <- view psLogger
    withCurrentCheckpointer "execPreInsertCheckReq" $ \pdb -> do
      let v = _chainwebVersion psEnv
          cid = _chainId psEnv
      liftIO $ fmap Discard $
        validateChainwebTxs logger v cid cp parentTime currHeight txs (runGas pdb psState psEnv)
  where
    runGas pdb pst penv ts =
        evalPactServiceM pst penv (attemptBuyGas noMiner pdb ts)

execLookupPactTxs
    :: CanReadablePayloadCas tbl
    => Rewind
    -> Maybe ConfirmationDepth
    -> Vector P.PactHash
    -> PactServiceM tbl (HM.HashMap P.PactHash (T2 BlockHeight BlockHash))
execLookupPactTxs restorePoint confDepth txs
    | V.null txs = return mempty
    | otherwise = go
  where
    go = getCheckpointer >>= \(!cp) -> case restorePoint of
      NoRewind _ ->
        liftIO $! _cpLookupProcessedTx cp confDepth txs
      DoRewind parent -> withDiscardedBatch $ do
        withCheckpointerRewind Nothing (Just $ ParentHeader parent) "lookupPactTxs" $ \_ ->
          liftIO $ Discard <$> _cpLookupProcessedTx cp confDepth txs

-- | Modified table gas module with free module loads
--
freeModuleLoadGasModel :: P.GasModel
freeModuleLoadGasModel = modifiedGasModel
  where
    defGasModel = tableGasModel defaultGasConfig
    fullRunFunction = P.runGasModel defGasModel
    modifiedRunFunction name ga = case ga of
      P.GPostRead P.ReadModule {} -> 0
      _ -> fullRunFunction name ga
    modifiedGasModel = defGasModel { P.runGasModel = modifiedRunFunction }

chainweb213GasModel :: P.GasModel
chainweb213GasModel = modifiedGasModel
  where
    defGasModel = tableGasModel gasConfig
    unknownOperationPenalty = 1000000
    multiRowOperation = 40000
    gasConfig = defaultGasConfig { _gasCostConfig_primTable = updTable }
    updTable = M.union upd defaultGasTable
    upd = M.fromList
      [("keys",    multiRowOperation)
      ,("select",  multiRowOperation)
      ,("fold-db", multiRowOperation)
      ]
    fullRunFunction = P.runGasModel defGasModel
    modifiedRunFunction name ga = case ga of
      P.GPostRead P.ReadModule {} -> 0
      P.GUnreduced _ts -> case M.lookup name updTable of
        Just g -> g
        Nothing -> unknownOperationPenalty
      _ -> fullRunFunction name ga
    modifiedGasModel = defGasModel { P.runGasModel = modifiedRunFunction }


getGasModel :: TxContext -> P.GasModel
getGasModel ctx
    | chainweb213Pact (ctxVersion ctx) (ctxChainId ctx) (ctxCurrentBlockHeight ctx) = chainweb213GasModel
    | otherwise = freeModuleLoadGasModel
