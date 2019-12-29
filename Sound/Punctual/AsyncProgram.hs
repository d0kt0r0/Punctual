{-# LANGUAGE JavaScriptFFI, OverloadedStrings #-}

module Sound.Punctual.AsyncProgram where

-- thanks to toji for the Javascript model of asynchronous shader compilation!
-- cf. https://github.com/toji/shader-perf/blob/gh-pages/async-program.js
-- the model is adapted here to the somewhat different challenge of repeatedly
-- updated shader programs (eg. where use might be attempted quickly right
-- after new shaders are provided with an already existing program still available)

import GHCJS.Types
import GHCJS.DOM.Types hiding (Text)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as T
import Data.Map.Strict as Map
import Control.Monad
import Data.Maybe

import Sound.Punctual.GL

data AsyncProgram = AsyncProgram {
  nextProgram :: Maybe WebGLProgram,
  nextVertexShader :: Maybe WebGLShader,
  nextFragmentShader :: Maybe WebGLShader,
  activeProgram :: Maybe WebGLProgram,
  uniformsMap :: Map Text WebGLUniformLocation
  }

emptyAsyncProgram :: AsyncProgram
emptyAsyncProgram = AsyncProgram {
  nextProgram = Nothing,
  nextVertexShader = Nothing,
  nextFragmentShader = Nothing,
  activeProgram = Nothing,
  uniformsMap = empty
  }

updateAsyncProgram :: AsyncProgram -> Text -> Text -> GL AsyncProgram
updateAsyncProgram a vSrc fSrc = do
  p <- createProgram
  v <- createVertexShader
  attachShader p v
  shaderSource v vSrc
  compileShader v
  f <- createFragmentShader
  attachShader p f
  shaderSource f fSrc
  compileShader f
  linkProgram p
  return $ a {
    nextProgram = Just p,
    nextVertexShader = Just v,
    nextFragmentShader = Just f
  }

-- returns true if a new program is going to be used for the first time
-- eg. to indicate the new uniform/attrib locations exist
useAsyncProgram :: AsyncProgram -> [Text] -> GL (Bool,AsyncProgram)
useAsyncProgram a uniformNames = do
  -- first check if we have an updated program that might be ready
  (newProgramUsed,a'') <- if (isNothing $ nextProgram a) then (return (False,a)) else do
    let nextProgram' = fromJust $ nextProgram a
    ls <- linkStatus nextProgram'
    case ls of
      0 -> return (False,a) -- new program not ready or compile/link failed
      1 -> do -- compile/link of new program succeeded, so make it the active program and query location of uniforms
        newUniformsMap <- mapM (getUniformLocation nextProgram') $ fromList $ fmap (\x -> (x,x)) uniformNames
        deleteShader $ fromJust $ nextVertexShader a
        deleteShader $ fromJust $ nextFragmentShader a
        when (isJust $ activeProgram a) $ deleteProgram $ fromJust $ activeProgram a
        let a' = a {
          activeProgram = Just nextProgram',
          nextProgram = Nothing,
          nextVertexShader = Nothing,
          nextFragmentShader = Nothing,
          uniformsMap = newUniformsMap
        }
        return (True,a')
  when (isJust $ activeProgram a'') $ useProgram $ fromJust $ activeProgram a''
  return (newProgramUsed,a'')

uniform1fAsync :: AsyncProgram -> Text -> Double -> GL ()
uniform1fAsync a n v = do
  let loc = Map.lookup n $ uniformsMap a
  when (isJust loc) $ uniform1f (fromJust loc) v

uniform2fAsync :: AsyncProgram -> Text -> Double -> Double -> GL ()
uniform2fAsync a n v1 v2 = do
  let loc = Map.lookup n $ uniformsMap a
  when (isJust loc) $ uniform2f (fromJust loc) v1 v2
