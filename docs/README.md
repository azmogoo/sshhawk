# Documentation SSHawk

Ce dossier contient les sources du **rapport de projet** (LaTeX) et les captures d'écran intégrées au PDF.

Le rapport livrable se trouve à la racine du dépôt : [`../PROJECT_REPORT.pdf`](../PROJECT_REPORT.pdf).

## Contenu

| Élément | Rôle |
|---------|------|
| `PROJECT_REPORT.tex` | Source LaTeX du rapport (français) |
| `screenshots/` | Captures d'écran pour la section démonstration |
| `assets/` | Logo JUNIA (`logo-junia-officiel.png`) pour la page de garde |

## Compiler le PDF

### Prérequis (Ubuntu)

```bash
sudo apt update
sudo apt install -y texlive-latex-base texlive-latex-extra texlive-lang-french \
  texlive-fonts-recommended
```

### Commandes

```bash
cd docs
pdflatex -interaction=nonstopmode PROJECT_REPORT.tex
pdflatex -interaction=nonstopmode PROJECT_REPORT.tex
cp PROJECT_REPORT.pdf ../PROJECT_REPORT.pdf
```

La deuxième passe met à jour la table des matières et la liste des figures.

Alternative : `latexmk -pdf PROJECT_REPORT.tex` puis copier le PDF à la racine.

## Artefacts ignorés par Git

Les fichiers `.aux`, `.log`, `.out`, `.toc`, `.lof` et le PDF dans `docs/` ne sont pas versionnés (voir `.gitignore`).
