The goal of this repository is to convert an informal description of a mathematical proof
into a formal proof that can be checked by a machine using Lean 4.

# Preliminaries

We will use Verso and [Verso Blueprint](https://github.com/leanprover/verso-blueprint) to create a formalization plan and manage progress.

Relevent repository with instructions for porting TeX to Verso Blueprints:
https://github.com/ejgallego/leanblueprint-to-verso


# Plan

Step 1 - convert the markdown to a Verso document.
Use existing Verso Blueprint support for referencing original markdown text.
Leave the node selection and the dependency resolution for a later phase.

## Subdirectory Build Configuration
Instead of using the parent project build system, we maintain a minimal local `lakefile.toml` and `lean-toolchain` configuration in this subdirectory targeting Lean 4.30.0 (and matching `verso-blueprint` and `mathlib4` dependencies).

## Lessons Learned & Verso Quirks

We have established a few important rules for working with `VersoBlueprint` in Lean 4.30.0:

1. **Executable Generation**: The `BlueprintMain.lean` executable should use `Informal.PreviewManifest.manualMainWithPreviewData (%doc <MainFile>) args (extensionImpls := by exact extension_impls%)` rather than `blueprintMain`.
2. **Main File Layout**:
   - Must `import VersoBlueprint` and `open Informal`.
   - The document genre should be `#doc (Manual)`.
   - To render UI components, import `VersoBlueprint.Commands.Graph` (plus `.Summary` and `.Bibliography`) and use the `{blueprint_graph}`, `{blueprint_summary}`, and `{blueprint_bibliography}` macros at the end of the main manual file.
3. **Math Syntax**:
   - Verso has strict inline math delimiters: use `$`...`` instead of the standard `$`...`$`.
   - For display math, use `$$`...`` instead of `$$`...`$$`.
4. **Markdown Witnesses**:
   - To provide the original markdown as a witness for blueprint tracking, wrap it in an `md` code block (````md ... ````), not `markdown`. `VersoBlueprint`'s internal handlers only recognize `md` or `tex` languages.