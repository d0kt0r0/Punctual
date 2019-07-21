{-# LANGUAGE OverloadedStrings #-}

module Sound.Punctual.Parser (runPunctualParser) where

import Data.Text (Text)
import qualified Data.Text as T
import Text.Parsec
import Text.Parsec.Text

import Sound.Punctual.Token
import Sound.Punctual.Extent
import Sound.Punctual.Graph
import Sound.Punctual.Types

duration :: Parser Duration
duration = choice $ fmap try [seconds,milliseconds,cycles]

seconds :: Parser Duration
seconds = do
  x <- double
  reserved "s"
  return $ Seconds x

milliseconds :: Parser Duration
milliseconds = do
  x <- double
  reserved "ms"
  return $ Seconds (x/1000.0)

cycles :: Parser Duration
cycles = do
  x <- double
  reserved "c"
  return $ Cycles x

cyclesInQuant :: Parser Double
cyclesInQuant = do
  x <- double
  reserved "c"
  return x

defTimeParser :: Parser DefTime
defTimeParser = reservedOp "@" >> choice [
  try $ quant,
  try $ cyclesInQuant >>= \n -> return (Quant n (Seconds 0.0)),
  try $ seconds >>= return . After,
  try $ milliseconds >>= return . After
  ]

quant :: Parser DefTime
quant = do
  x <- cyclesInQuant
  reservedOp "+"
  y <- duration
  return $ Quant x y

transitionParser :: Parser Transition
transitionParser = choice [
  reservedOp "<>" >> return DefaultCrossFade,
  reservedOp "~" >> return HoldPhase,
  reservedOp "=" >> return (CrossFade (Seconds 0.0)),
  CrossFade <$> angles duration
  ]

definitionParser :: Parser Definition
definitionParser = do
  a <- option Anonymous $ (Explicit . T.pack <$> identifier)
  b <- option (Quant 1 (Seconds 0)) defTimeParser
  c <- option DefaultCrossFade  transitionParser
  d <- graphParser
  return $ Definition a b c d

outputParser :: Parser Output
outputParser = choice [
  try $ reservedOp "=>" >> (PannedOutput <$> extent),
  try $ reservedOp "=>" >> reserved "left" >> return (PannedOutput 0),
  try $ reservedOp "=>" >> reserved "right" >> return (PannedOutput 1),
  try $ reservedOp "=>" >> reserved "centre" >> return (PannedOutput 0.5),
  try $ reservedOp "=>" >> reserved "splay" >> return (NamedOutput "splay"),
  try $ reservedOp "=>" >> reserved "red" >> return (NamedOutput "red"),
  try $ reservedOp "=>" >> reserved "green" >> return (NamedOutput "green"),
  try $ reservedOp "=>" >> reserved "blue" >> return (NamedOutput "blue"),
  try $ reservedOp "=>" >> reserved "alpha" >> return (NamedOutput "alpha"),
  try $ reservedOp "=>" >> reserved "rgb" >> return (NamedOutput "rgb"),
  return NoOutput
  ]

expression :: Parser Expression
expression = Expression <$> definitionParser <*> outputParser

punctualParser :: Parser [Expression]
punctualParser = do
  whiteSpace
  x <- expression `sepBy` reservedOp ";"
  eof
  return x

runPunctualParser :: Text -> Either ParseError [Expression]
runPunctualParser = parse punctualParser ""

graphParser :: Parser Graph
graphParser = sumOfGraphs <|> return EmptyGraph

sumOfGraphs :: Parser Graph
sumOfGraphs = chainl1 comparisonOfGraphs $ choice [
  reservedOp "+" >> return Sum,
  reservedOp "-" >> return (\x y -> Sum x (Product y (Constant (-1))))
  ]

comparisonOfGraphs :: Parser Graph
comparisonOfGraphs = chainl1 productOfGraphs $ choice [
  reservedOp ">" >> return GreaterThan,
  reservedOp "<" >> return LessThan,
  reservedOp ">=" >> return GreaterThanOrEqual,
  reservedOp "<=" >> return LessThanOrEqual,
  reservedOp "==" >> return Equal,
  reservedOp "!=" >> return NotEqual
  ]

productOfGraphs :: Parser Graph
productOfGraphs = chainl1 simpleGraph $ choice [
  reservedOp "*" >> return Product,
  reservedOp "/" >> return Division
  ]

simpleGraph :: Parser Graph
simpleGraph = choice [
    try $ modulatedRange,
    Constant <$> extent,
    reserved "noise" >> return Noise,
    reserved "pink" >> return Pink,
    reserved "fx" >> return Fx,
    reserved "fy" >> return Fy,
    reserved "px" >> return Px,
    reserved "py" >> return Py,
    (reserved "abs" >> return Abs) <*> graphArgument,
    (reserved "cpsmidi" >> return CpsMidi) <*> graphArgument,
    (reserved "midicps" >> return MidiCps) <*> graphArgument,
    (reserved "dbamp" >> return DbAmp) <*> graphArgument,
    (reserved "ampdb" >> return AmpDb) <*> graphArgument,
    (reserved "point" >> return point) <*> graphArgument <*> graphArgument,
    (reserved "hline" >> return hline) <*> graphArgument,
    (reserved "vline" >> return vline) <*> graphArgument,
    (reserved "linlin" >> return linlin) <*> graphArgument <*> graphArgument <*> graphArgument <*> graphArgument <*> graphArgument,
    (reserved "rect" >> return rect) <*> graphArgument <*> graphArgument <*> graphArgument <*> graphArgument,
    oscillators,
    filters,
    mixGraph,
    multiGraph,
    functions,
    -- FromTarget <$> lexeme identifier
    try $ parens graphParser
    ]

linlin :: Graph -> Graph -> Graph -> Graph -> Graph -> Graph
linlin min1 max1 min2 max2 x = Sum min2 (Product outputRange proportion)
  where
    inputRange = difference max1 min1
    outputRange = difference max2 min2
    proportion = Division (difference x min1) inputRange

rect :: Graph -> Graph -> Graph -> Graph -> Graph
rect x y w h = Product inHrange inVrange
  where
    x0 = Sum x (Product w (Constant (-0.5)))
    x1 = Sum x (Product w (Constant (0.5)))
    y0 = Sum y (Product h (Constant (-0.5)))
    y1 = Sum y (Product h (Constant (0.5)))
    inHrange = Product (GreaterThanOrEqual Fx x0) (LessThanOrEqual Fx x1)
    inVrange = Product (GreaterThanOrEqual Fy y0) (LessThanOrEqual Fy y1)

point :: Graph -> Graph -> Graph
point x y = Product inHrange inVrange
  where
    x0 = Sum x (Product Px (Constant (-0.5)))
    x1 = Sum x (Product Px (Constant (0.5)))
    y0 = Sum y (Product Py (Constant (-0.5)))
    y1 = Sum y (Product Py (Constant (0.5)))
    inHrange = Product (GreaterThanOrEqual Fx x0) (LessThanOrEqual Fx x1)
    inVrange = Product (GreaterThanOrEqual Fy y0) (LessThanOrEqual Fy y1)

hline :: Graph -> Graph
hline y = Product (GreaterThanOrEqual Fy y0) (LessThanOrEqual Fy y1)
  where
    y0 = Sum y (Product Py (Constant (-0.5)))
    y1 = Sum y (Product Py (Constant (0.5)))

vline :: Graph -> Graph
vline x = Product (GreaterThanOrEqual Fx x0) (LessThanOrEqual Fx x1)
  where
    x0 = Sum x (Product Px (Constant (-0.5)))
    x1 = Sum x (Product Px (Constant (0.5)))

graphArgument :: Parser Graph
graphArgument = choice [
  try $ parens graphParser,
  multiGraph,
  Constant <$> try extent,
  reserved "noise" >> return Noise,
  reserved "pink" >> return Pink,
  reserved "fx" >> return Fx,
  reserved "fy" >> return Fy
  ]

modulatedRange :: Parser Graph
modulatedRange = do
  (a,b) <- rangeParser
  reservedOp ":"
  m <- graphParser
  return $ modulatedRangeGraph a b m

modulatedRangeGraph :: Graph -> Graph -> Graph -> Graph
modulatedRangeGraph low high m = Sum (average low high) (Product (Product (difference high low) (Constant 0.5)) m)

average :: Graph -> Graph -> Graph
average x y = Product (Sum x y) (Constant 0.5)

rangeParser :: Parser (Graph,Graph)
rangeParser = choice [
  try $ do
    x <- graphArgument
    reservedOp "+-"
    y <- graphArgument
    let y' = Product x y
    return (difference x y',Sum x y'),
  try $ do
    x <- graphArgument
    reservedOp ".."
    y <- graphArgument
    return (x,y),
  try $ do
    x <- graphArgument
    return (Constant 0,x)
  ]

difference :: Graph -> Graph -> Graph
difference x y = Sum x (Product y (Constant (-1)))

oscillators :: Parser Graph
oscillators = choice [
  Sine <$> (reserved "sin" >> graphArgument),
  Tri <$> (reserved "tri" >> graphArgument),
  Saw <$> (reserved "saw" >> graphArgument),
  Square <$> (reserved "sqr" >> graphArgument)
  ]

filters :: Parser Graph
filters = do
  x <- (reserved "lpf" >> return LPF) <|> (reserved "hpf" >> return HPF)
  x <$> graphArgument <*> graphArgument <*> graphArgument

mixGraph :: Parser Graph
mixGraph = do
  reserved "mix"
  mixGraphs <$> brackets (commaSep graphParser)

multiGraph :: Parser Graph
multiGraph = choice [
  try $ multiGraph' >>= (\x -> reserved "db" >> return (DbAmp x)),
  try $ multiGraph' >>= (\x -> reserved "m" >> return (MidiCps x)),
  multiGraph'
  ]

multiGraph' :: Parser Graph
multiGraph' = brackets (commaSep graphParser) >>= return . Multi

functions :: Parser Graph
functions = choice [
  (reserved "bipolar" >> return bipolar) <*> graphArgument,
  (reserved "unipolar" >> return unipolar) <*> graphArgument
  ]

bipolar :: Graph -> Graph
bipolar x = Sum (Product x (Constant 2)) (Constant (-1))

unipolar :: Graph -> Graph
unipolar x = Sum (Product x (Constant 0.5)) (Constant 0.5)
