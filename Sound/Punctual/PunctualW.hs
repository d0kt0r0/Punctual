{-# LANGUAGE OverloadedStrings #-}

module Sound.Punctual.PunctualW where

-- This module provides an implementation of Punctual using MusicW as an underlying synthesis library

import Control.Monad (when)
import Control.Monad.IO.Class
import Control.Concurrent
import Data.Time
import Data.Maybe
import Data.IntMap.Strict

import Sound.Punctual.Graph hiding (difference)
import Sound.Punctual.Target
import Sound.Punctual.Definition
import Sound.Punctual.Evaluation
import Sound.MusicW (AudioIO,SynthDef,Synth,AudioContext,Node,NodeRef)
import qualified Sound.MusicW as W

data PunctualW = PunctualW {
  punctualAudioContext :: AudioContext,
  punctualDestination :: Node,
  punctualChannels :: Int,
  silentSynthLaunched :: Bool,
  prevSynthsNodes :: IntMap (Synth W.AudioContextIO, Node),
  punctualState :: PunctualState
  }

emptyPunctualW :: AudioContext -> Node -> Int -> AudioTime -> PunctualW
emptyPunctualW ac dest nchnls t = PunctualW {
  punctualAudioContext = ac,
  punctualDestination = dest,
  punctualChannels = nchnls,
  silentSynthLaunched = False,
  prevSynthsNodes = empty,
  punctualState = emptyPunctualState t
  }

expressionHasAudioTarget :: Expression -> Bool
expressionHasAudioTarget (Expression _ (NamedOutput "splay")) = True
expressionHasAudioTarget (Expression _ (PannedOutput _)) = True
expressionHasAudioTarget _ = False

updatePunctualW :: PunctualW -> (AudioTime,Double) -> Evaluation -> W.AudioContextIO PunctualW
updatePunctualW s tempo e@(p,t) = do
  t1 <- liftIO $ getCurrentTime
  let xs = expressions p
  let evalTime = t + 0.2
  let dest = punctualDestination s
  let exprs = Map.filter expressionHasAudioTarget $ listOfExpressionsToMap xs -- Map Target' Expression
  mapM_ (deleteSynth evalTime evalTime (0.050 + evalTime)) $ difference (prevSynthsNodes s) exprs -- delete synths no longer present
  addedSynthsNodes <- mapM (addNewSynth dest tempo evalTime) $ difference exprs (prevSynthsNodes s) -- add synths newly present
  let continuingSynthsNodes = intersection (prevSynthsNodes s) exprs
  updatedSynthsNodes <- sequence $ intersectionWith (updateSynth dest tempo evalTime) continuingSynthsNodes exprs
  let newSynthsNodes = union addedSynthsNodes updatedSynthsNodes
  let newState = updatePunctualState (punctualState s) e
  when (not $ silentSynthLaunched s) $ do
    W.playSynth dest t $ W.constantSource 0 >>= W.audioOut
    return ()
  t2 <- liftIO $ getCurrentTime
  liftIO $ putStrLn $ "updatePunctualW (audio): " ++ show (round (diffUTCTime t2 t1 * 1000) :: Int) ++ " ms"
  return $ s { punctualState = newState, prevSynthsNodes = newSynthsNodes, silentSynthLaunched = True }

addNewSynth :: AudioIO m => W.Node -> (AudioTime,Double) -> AudioTime -> Expression -> m (Synth m, W.Node)
addNewSynth dest tempo evalTime expr = do
  let (xfadeStart,xfadeEnd) = expressionToTimes tempo evalTime expr
  addSynth dest xfadeStart xfadeStart xfadeEnd expr

updateSynth :: AudioIO m => W.Node -> (AudioTime,Double) -> AudioTime -> (Synth m, W.Node) -> Expression -> m (Synth m, W.Node)
updateSynth dest tempo evalTime prevSynthNode expr = do
  let (xfadeStart,xfadeEnd) = expressionToTimes tempo evalTime expr
  deleteSynth evalTime xfadeStart xfadeEnd prevSynthNode
  addSynth dest xfadeStart xfadeStart xfadeEnd def

addSynth :: AudioIO m => W.Node -> AudioTime -> AudioTime -> AudioTime -> Definition -> m (Synth m, W.Node)
addSynth dest startTime xfadeStart xfadeEnd def = do
  let xfadeStart' = xfadeStart - startTime
  let xfadeEnd' = xfadeEnd - startTime
  (newNodeRef,newSynth) <- W.playSynth dest startTime $ do
    gainNode <- definitionToSynthDef def
    W.setParam W.Gain 0.0 0.0 gainNode
    W.setParam W.Gain 0.0 xfadeStart' gainNode
    W.linearRampOnParam W.Gain 1.0 xfadeEnd' gainNode
    mapM_ (connectSynthToOutput gainNode) $ targets def
    return gainNode
  newNode <- W.nodeRefToNode newNodeRef newSynth
  return (newSynth,newNode)

connectSynthToOutput :: AudioIO m => NodeRef -> Target -> SynthDef m ()
connectSynthToOutput nRef (Panned p) = do
  xs <- W.channelSplitter nRef
  y <- W.mix xs
  z <- W.equalPowerPan p y
  W.audioOut z
connectSynthToOutput nRef Splay = do
  xs <- W.channelSplitter nRef
  y <- W.splay 2 xs
  W.audioOut y
connectSynthToOutput _ _ = return () -- all other types of targets are not (directly) connected to audio output

deleteSynth :: MonadIO m => AudioTime -> AudioTime -> AudioTime -> (Synth m, W.Node) -> m ()
deleteSynth evalTime xfadeStart xfadeEnd (prevSynth,prevGainNode) = do
  W.setValueAtTime prevGainNode W.Gain 1.0 xfadeStart
  W.linearRampToValueAtTime prevGainNode W.Gain 0.0 xfadeEnd
  W.stopSynth xfadeEnd prevSynth
  let microseconds = ceiling $ (xfadeEnd - evalTime + 0.3) * 1000000
  --  ^ = kill synth 100ms after fade out
  liftIO $ forkIO $ do
    threadDelay microseconds
    W.disconnectSynth prevSynth
  return ()

definitionToSynthDef :: AudioIO m => Definition -> SynthDef m NodeRef
definitionToSynthDef def = do
  sd <- mapM graphToSynthDef $ expandMultis $ graph def
  cm <- W.channelMerger sd
  W.gain 0 cm

graphToSynthDef :: AudioIO m => Graph -> SynthDef m NodeRef

graphToSynthDef (Multi _) = error "internal error: graphToSynthDef should only be used post multi-channel expansion (can't handle Multi)"

graphToSynthDef (Mono _) = error "internal error: graphToSynthDef should only be used post multi-channel expansion (can't handle Mono)"

graphToSynthDef (Constant x) = W.constantSource x

-- for now, audio analysis not available in audio graphs
graphToSynthDef Lo = W.constantSource 0
graphToSynthDef Mid = W.constantSource 0
graphToSynthDef Hi = W.constantSource 0

graphToSynthDef (Bipolar x) = graphToSynthDef $ x * 2 - 1
graphToSynthDef (Unipolar x) = graphToSynthDef $ x * 0.5 + 0.5

graphToSynthDef (Sine (MidiCps (Constant x))) = W.oscillator W.Sine $ W.midicps x
graphToSynthDef (Sine (Constant x)) = W.oscillator W.Sine x
graphToSynthDef (Sine x) = do
  s <- W.oscillator W.Sine 0
  graphToSynthDef x >>= W.param W.Frequency s
  return s

graphToSynthDef (Tri (MidiCps (Constant x))) = W.oscillator W.Triangle $ W.midicps x
graphToSynthDef (Tri (Constant x)) = W.oscillator W.Triangle x
graphToSynthDef (Tri x) = do
  s <- W.oscillator W.Triangle 0
  graphToSynthDef x >>= W.param W.Frequency s
  return s

graphToSynthDef (Saw (MidiCps (Constant x))) = W.oscillator W.Sawtooth $ W.midicps x
graphToSynthDef (Saw (Constant x)) = W.oscillator W.Sawtooth x
graphToSynthDef (Saw x) = do
  s <- W.oscillator W.Sawtooth 0
  graphToSynthDef x >>= W.param W.Frequency s
  return s

graphToSynthDef (Square (MidiCps (Constant x))) = W.oscillator W.Square $ W.midicps x
graphToSynthDef (Square (Constant x)) = W.oscillator W.Square x
graphToSynthDef (Square x) = do
  s <- W.oscillator W.Square 0
  graphToSynthDef x >>= W.param W.Frequency s
  return s

graphToSynthDef (LPF i (Constant f) (Constant q)) = graphToSynthDef i >>= W.biquadFilter (W.LowPass f q)
graphToSynthDef (LPF i (Constant f) q) = do
  x <- graphToSynthDef i >>= W.biquadFilter (W.LowPass f 0)
  graphToSynthDef q >>= W.param W.Q x
  return x
graphToSynthDef (LPF i f (Constant q)) = do
  x <- graphToSynthDef i >>= W.biquadFilter (W.LowPass 0 q)
  graphToSynthDef f >>= W.param W.Frequency x
  return x
graphToSynthDef (LPF i f q) = do
  x <- graphToSynthDef i >>= W.biquadFilter (W.LowPass 0 0)
  graphToSynthDef f >>= W.param W.Frequency x
  graphToSynthDef q >>= W.param W.Q x
  return x

graphToSynthDef (HPF i (Constant f) (Constant q)) = graphToSynthDef i >>= W.biquadFilter (W.HighPass f q)
graphToSynthDef (HPF i (Constant f) q) = do
  x <- graphToSynthDef i >>= W.biquadFilter (W.HighPass f 0)
  graphToSynthDef q >>= W.param W.Q x
  return x
graphToSynthDef (HPF i f (Constant q)) = do
  x <- graphToSynthDef i >>= W.biquadFilter (W.HighPass 0 q)
  graphToSynthDef f >>= W.param W.Frequency x
  return x
graphToSynthDef (HPF i f q) = do
  x <- graphToSynthDef i >>= W.biquadFilter (W.HighPass 0 0)
  graphToSynthDef f >>= W.param W.Frequency x
  graphToSynthDef q >>= W.param W.Q x
  return x

graphToSynthDef (FromTarget x) = W.constantSource 0 -- placeholder

graphToSynthDef (Sum (Constant x) (Constant y)) = graphToSynthDef (Constant $ x+y)
graphToSynthDef (Sum x y) = W.mixSynthDefs $ fmap graphToSynthDef [x,y]

graphToSynthDef (Product (Constant x) (Constant y)) = graphToSynthDef (Constant $ x*y)
graphToSynthDef (Product x (DbAmp (Constant y))) = graphToSynthDef x >>= W.gain (W.dbamp y)
graphToSynthDef (Product (DbAmp (Constant x)) y) = graphToSynthDef y >>= W.gain (W.dbamp x)
graphToSynthDef (Product x (Constant y)) = graphToSynthDef x >>= W.gain y
graphToSynthDef (Product (Constant x) y) = graphToSynthDef y >>= W.gain x
graphToSynthDef (Product x y) = do
  m <- graphToSynthDef x >>= W.gain 0.0
  graphToSynthDef y >>= W.param W.Gain m
  return m

graphToSynthDef (Mean x y) = graphToSynthDef $ (x + y) * 0.5
graphToSynthDef (Max x y) = graphToSynthDef $ (GreaterThanOrEqual x y * x) + (LessThan x y * y)
graphToSynthDef (Min x y) = graphToSynthDef $ (GreaterThanOrEqual x y * y) + (LessThan x y * x)

graphToSynthDef (Division x y) = do
  x' <- graphToSynthDef x
  y' <- graphToSynthDef y
  W.safeDivideWorklet x' y'

graphToSynthDef (GreaterThan x y) = do
  x' <- graphToSynthDef x
  y' <- graphToSynthDef y
  W.greaterThanWorklet x' y'

graphToSynthDef (GreaterThanOrEqual x y) = do
  x' <- graphToSynthDef x
  y' <- graphToSynthDef y
  W.greaterThanOrEqualWorklet x' y'

graphToSynthDef (LessThan x y) = do
  x' <- graphToSynthDef x
  y' <- graphToSynthDef y
  W.lessThanWorklet x' y'

graphToSynthDef (LessThanOrEqual x y) = do
  x' <- graphToSynthDef x
  y' <- graphToSynthDef y
  W.lessThanOrEqualWorklet x' y'

graphToSynthDef (Equal x y) = do
  x' <- graphToSynthDef x
  y' <- graphToSynthDef y
  W.equalWorklet x' y'

graphToSynthDef (NotEqual x y) = do
  x' <- graphToSynthDef x
  y' <- graphToSynthDef y
  W.notEqualWorklet x' y'

graphToSynthDef (MidiCps (Constant x)) = W.constantSource $ W.midicps x
graphToSynthDef (MidiCps x) = graphToSynthDef x >>= W.midiCpsWorklet

graphToSynthDef (CpsMidi x) = graphToSynthDef x >>= W.cpsMidiWorklet

graphToSynthDef (DbAmp (Constant x)) = W.constantSource $ W.dbamp x
graphToSynthDef (DbAmp x) = graphToSynthDef x >>= W.dbAmpWorklet

graphToSynthDef (AmpDb x) = graphToSynthDef x >>= W.ampDbWorklet

graphToSynthDef (Abs x) = graphToSynthDef x >>= W.absWorklet

graphToSynthDef (Sqrt x) = graphToSynthDef x >>= W.sqrtWorklet

graphToSynthDef (Pow x y) = do
  x' <- graphToSynthDef x
  y' <- graphToSynthDef y
  W.powWorklet x' y'

graphToSynthDef (Floor x) = graphToSynthDef x >>= W.floorWorklet

graphToSynthDef (Fract x) = graphToSynthDef x >>= W.fractWorklet

graphToSynthDef (Clip x y z) = do
  x' <- graphToSynthDef x
  y' <- graphToSynthDef y
  z' <- graphToSynthDef z
  W.clipWorklet x' y' z'

graphToSynthDef (Between r1 r2 x) = graphToSynthDef g
  where g = (GreaterThan r2 r1) * (GreaterThan x r1) * (LessThan x r2) +
            (GreaterThan r1 r2) * (GreaterThan x r2) * (LessThan x r1)

graphToSynthDef (LinLin min1 max1 min2 max2 x) = graphToSynthDef $ min2 + outputRange * proportion
  where
    inputRange = max1 - min1
    outputRange = max2 - min2
    proportion = Division (x - min1) inputRange

-- Graph constructors that have no meaning in the audio domain all produce a constant signal of 0
graphToSynthDef (VLine _ _) = W.constantSource 0
graphToSynthDef (HLine _ _) = W.constantSource 0
graphToSynthDef (ILine _ _ _ _ _) = W.constantSource 0
graphToSynthDef (Line _ _ _ _ _) = W.constantSource 0
graphToSynthDef (Rect _ _ _ _) = W.constantSource 0
graphToSynthDef (Point _ _) = W.constantSource 0
graphToSynthDef (Circle _ _ _) = W.constantSource 0
graphToSynthDef (Distance _ _) = W.constantSource 0
graphToSynthDef Fx = W.constantSource 0
graphToSynthDef Fy = W.constantSource 0
graphToSynthDef Px = W.constantSource 0
graphToSynthDef Py = W.constantSource 0
graphToSynthDef (TexR _ _ _) = W.constantSource 0
graphToSynthDef (TexG _ _ _) = W.constantSource 0
graphToSynthDef (TexB _ _ _) = W.constantSource 0
