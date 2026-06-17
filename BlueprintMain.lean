import VersoManual
import VersoBlueprint.PreviewManifest
import DominoPuzzleProof

open Verso Doc
open Verso.Genre Manual

def main (args : List String) : IO UInt32 :=
  Informal.PreviewManifest.manualMainWithPreviewData
    (%doc DominoPuzzleProof)
    args
    (extensionImpls := by exact extension_impls%)
