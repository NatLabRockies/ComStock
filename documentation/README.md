# ComStock Documentation

This describes how to compile the **ComStock Reference Documentation PDF** from the LaTeX
sources in `reference_doc/`.

## Requirements

- A TeX distribution with **pdfTeX** and **latexmk**. [TeX Live](https://www.tug.org/texlive/)
  (full scheme) is recommended on every platform; MiKTeX also works if automatic package
  installation is left on. The `nrel` document class uses pdfTeX-only primitives, so
  XeLaTeX, LuaLaTeX, and tectonic cannot compile it.
- **biber**, which TeX Live installs with biblatex. The bibliography is biblatex with the
  biber backend, so plain bibtex will not resolve citations.
- Python 3 (standard library only) for the pre-compile checks and table generation, and
  matplotlib for the schedule figures. See `reference_doc/scripts/README.md`.

## Compiling

From the command line:

```bash
cd documentation/reference_doc
latexmk
```

`reference_doc/latexmkrc` selects pdflatex and biber, writes everything to
`reference_doc/output/`, and reruns the compiler until the references settle. The result is
`output/main.pdf`; warnings and errors are in `output/main.log`. `latexmk -C` removes the
build output.

Equivalent manual sequence, run from `reference_doc/`:

```bash
pdflatex -output-directory=output main && biber output/main && pdflatex -output-directory=output main && pdflatex -output-directory=output main
```

In VS Code, the [LaTeX Workshop](https://marketplace.visualstudio.com/items?itemName=James-Yu.latex-workshop)
extension uses the same `latexmkrc`: open `reference_doc/main.tex` and run
`LaTeX Workshop: Build LaTeX project`. The repository's `.vscode/settings.json` points its
output directory at `reference_doc/output` as well.

Before compiling, run the two checks (they are what the CI job runs first):

```bash
python documentation/reference_doc/scripts/check_refs.py
python documentation/reference_doc/scripts/check_tables.py
```

## Continuous integration

`.github/workflows/reference_doc.yml` runs on every push and pull request that touches
`documentation/reference_doc/`. It runs the two checks, compiles the PDF in a full TeX Live
container, and uploads `main.pdf` as a workflow artifact, so reviewers can read the
rendered document without a local TeX install. The build log is uploaded when the compile
fails.

## Updating for a new release

The title, release name, and author list live in `reference_doc/metadata.tex`. Edit that
file rather than `main.tex`. Data-driven tables and figures are regenerated with the
scripts in `reference_doc/scripts/`.

## Directory Structure

### `/reference_doc`

LaTeX files for the ComStock Reference Documentation

 - `main.tex`: the top level file for the document, which includes the others
 - `metadata.tex`: title, release, and authors
 - `latexmkrc`: build configuration (compiler, bibliography tool, output directory)
 - `nrel.cls`: the NREL report class
 - `chapter_section_topic.tex`: files for individual chapters and sections
 - `bibliography.bib`: references cited in the document
 - `/figures`: figures referenced in the document
 - `/tables`: individual `.tex` files for each table in the document; many are generated
 - `/scripts`: table and figure generators and the pre-compile checks
 - `/files`: NREL guidance on using the report class
 - `/output`: results of the compilation process (not committed)

### `/dependency-tree-flowchart`

Files that show the relationship between ComStock input
building characteristics.

### `/change_docs`

Working documents that the team creates to document changes to ComStock.
They are neither complete nor comprehensive of all the work that goes into the development process.
Not every change implemented by the team is documented here, based on time, budget, etc.
They are provided simply to share some insight into the model development process.
The ComStock Reference Documentation is modified to reflect the final state of the software,
and should be considered the authoritative source.
