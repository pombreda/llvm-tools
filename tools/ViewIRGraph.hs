module Main ( main ) where

import Control.Arrow
import Control.Monad.Identity
import Data.GraphViz
import Data.Maybe ( isNothing )
import Data.Monoid
import System.Console.CmdArgs.Explicit
import System.Console.CmdArgs.Text
import System.Exit

import LLVM.VisualizeGraph

import LLVM.Analysis
import LLVM.Analysis.CFG
import LLVM.Analysis.CDG
import LLVM.Analysis.CallGraph
import LLVM.Analysis.CallGraphSCCTraversal
import LLVM.Analysis.Dominance
import LLVM.Analysis.Escape
import LLVM.Analysis.PointsTo.TrivialFunction

data Opts = Opts { inputFile :: Maybe FilePath
                 , outputFile :: Maybe FilePath
                 , graphType :: Maybe GraphType
                 , outputFormat :: OutputType
                 , wantsHelp :: Bool
                 }

data GraphType = Cfg
               | Cdg
               | Cg
               | Domtree
               | Postdomtree
               | Escape
               deriving (Read, Show, Eq, Ord)

cmdOpts :: Opts -> Mode Opts
cmdOpts defs = mode "VisualizeGraph" defs desc infileArg as
  where
    infileArg = flagArg setInput "INPUT"
    desc = "A generic graph viewing frontend"
    as = [ flagReq ["output", "o"] setOutput "[FILE or DIR]" "The destination of a file output"
         , flagReq ["type", "t"] setType "[GRAPHTYPE]" "The graph requested.  One of Cfg, Cdg, Cg, Domtree, Postdomtree, Escape"
         , flagReq ["format", "f"] setFormat "GVOUT" "The type of output to produce: Gtk, Xlib, XDot, Eps, Jpeg, Pdf, Png, Ps, Ps2, Svg.  Default: Gtk"
         , flagHelpSimple setHelp
         ]

defaultOptions :: Opts
defaultOptions = Opts { inputFile = Nothing
                      , outputFile = Nothing
                      , graphType = Nothing
                      , outputFormat = CanvasOutput Gtk
                      , wantsHelp = False
                      }

showHelpAndExit :: Mode a -> IO b -> IO b
showHelpAndExit args exitCmd = do
  putStrLn $ showText (Wrap 80) $ helpText [] HelpFormatOne args
  exitCmd


main :: IO ()
main = do
  let arguments = cmdOpts defaultOptions
  opts <- processArgs arguments
  when (wantsHelp opts) (showHelpAndExit arguments exitSuccess)
  when (isNothing (inputFile opts)) $ do
    putStrLn "Input file not specified"
    showHelpAndExit arguments exitFailure
  when (isNothing (graphType opts)) $ do
    putStrLn "No graph type specified"
    showHelpAndExit arguments exitFailure

  let Just gt = graphType opts
      Just inFile = inputFile opts
      outFile = outputFile opts
      fmt = outputFormat opts

  case gt of
    Cfg -> visualizeGraph inFile outFile fmt optOptions mkCFGs cfgGraphvizRepr
    Cdg -> visualizeGraph inFile outFile fmt optOptions mkCDGs cdgGraphvizRepr
    Cg -> visualizeGraph inFile outFile fmt optOptions mkCG cgGraphvizRepr
    Domtree -> visualizeGraph inFile outFile fmt optOptions mkDTs domTreeGraphvizRepr
    Postdomtree -> visualizeGraph inFile outFile fmt optOptions mkPDTs postdomTreeGraphvizRepr
    Escape -> visualizeGraph inFile outFile fmt optOptions mkEscapeGraphs useGraphvizRepr
  where
    optOptions = [ "-mem2reg", "-basicaa" ]

mkPDTs :: Module -> [(String, PostdominatorTree)]
mkPDTs m = map (getFuncName &&& toTree) fs
  where
    fs = moduleDefinedFunctions m
    toTree = postdominatorTree . reverseCFG . mkCFG

mkDTs :: Module -> [(String, DominatorTree)]
mkDTs m = map (getFuncName &&& toTree) fs
  where
    fs = moduleDefinedFunctions m
    toTree = dominatorTree . mkCFG

mkCG :: Module -> [(String, CallGraph)]
mkCG m = [("Module", mkCallGraph m aa [])]
  where
    aa = runPointsToAnalysis m

mkCFGs :: Module -> [(String, CFG)]
mkCFGs m = map (getFuncName &&& mkCFG) fs
  where
    fs = moduleDefinedFunctions m

mkCDGs :: Module -> [(String, CDG)]
mkCDGs m = map (getFuncName &&& toCDG) fs
  where
    fs = moduleDefinedFunctions m
    toCDG = controlDependenceGraph . mkCFG

runEscapeAnalysis ::  CallGraph
                     -> (ExternalFunction -> Int -> Identity Bool)
                     -> EscapeResult
runEscapeAnalysis cg extSumm =
  let analysis :: [Function] -> EscapeResult -> EscapeResult
      analysis = callGraphAnalysisM runIdentity (escapeAnalysis extSumm)
  in callGraphSCCTraversal cg analysis mempty

--mkEscapeGraphs :: Module -> [(String,
mkEscapeGraphs m = escapeUseGraphs er
  where
    er = runEscapeAnalysis cg (\_ _ -> return True)
    cg = mkCallGraph m pta []
    pta = runPointsToAnalysis m

getFuncName :: Function -> String
getFuncName = identifierAsString . functionName



-- Command line helpers

setHelp :: Opts -> Opts
setHelp opts = opts { wantsHelp = True }

setInput :: String -> Opts -> Either String Opts
setInput inf opts@Opts { inputFile = Nothing } =
  Right opts { inputFile = Just inf }
setInput _ _ = Left "Only one input file is allowed"

setOutput :: String -> Opts -> Either String Opts
setOutput outf opts@Opts { outputFile = Nothing } =
  Right opts { outputFile = Just outf }
setOutput _ _ = Left "Only one output file is allowed"

setFormat :: String -> Opts -> Either String Opts
setFormat fmt opts =
  case fmt of
    "Html" -> Right opts { outputFormat = HtmlOutput }
    _ -> case reads fmt of
      [(Gtk, [])] -> Right opts { outputFormat = CanvasOutput Gtk }
      [(Xlib, [])] -> Right opts { outputFormat = CanvasOutput Xlib }
      _ -> case reads fmt of
        [(gout, [])] -> Right opts { outputFormat = FileOutput gout }
        _ -> Left ("Unrecognized output format: " ++ fmt)

setType :: String -> Opts -> Either String Opts
setType t opts =
  case reads t of
    [(t', [])] -> Right opts { graphType = Just t' }
    _ -> Left $ "Unsupported graph type: " ++ t
