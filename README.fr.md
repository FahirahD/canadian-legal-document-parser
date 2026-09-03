# Canadian Legal Document Parser

*[Read in English](README.md)*

Des analyseurs syntaxiques [PEG](https://en.wikipedia.org/wiki/Parsing_expression_grammar) écrits à la main, en [Mojo](https://www.modular.com/mojo), qui transforment de véritables documents juridiques canadiens (et québécois) en données structurées : **lois** fédérales, **jurisprudence** des tribunaux et **doctrine** académique. Chacun est construit à partir des conventions de mise en forme réelles de PDF publiés — pas un exemple jouet soigneusement préparé — et est bilingue (anglais/français) lorsque le document source l'est.

Mojo est conçu avant tout pour des charges de travail numériques et d'IA haute performance ; ce projet sert donc aussi de preuve de concept : il montre que Mojo peut tout aussi bien traiter un problème d'analyse syntaxique réel et fortement textuel — des grammaires de descente récursive écrites à la main sur du texte juridique bilingue, désordonné et issu de PDF — de bout en bout, avec une qualité de production.

## Pourquoi trois analyseurs, pas un seul

Les lois, la jurisprudence et la doctrine juridique sont structurées de façon complètement différente sur la page ; chacune a donc sa propre grammaire plutôt qu'un analyseur générique de « document juridique » :

| | Législation | Jurisprudence | Doctrine |
|---|---|---|---|
| **Ce que c'est** | Lois fédérales (PDF consolidés de Justice Laws) | Jugements/motifs des tribunaux | Articles de revue, chapitres de traités, commentaires d'arrêts |
| **Numérotation** | Clauses imbriquées `1`, `(1)`, `(a)`, `(i)` | Paragraphes entre crochets `[1]`, `[2]`, ... | Notes de bas de page séquentielles, pas de numéros de paragraphe |
| **Titres** | Lignes en casse de titre non étiquetées, mentions « Note marginale : » | Titres romains/lettrés `I.` / `A.`, titres en MAJUSCULES simples | Même convention romaine/lettrée/simple que la jurisprudence |
| **Langue** | Bilingue FR/EN, mise en page à deux colonnes | Étiquettes d'en-tête bilingues FR/EN | Étiquettes de métadonnées bilingues FR/EN |

## Ce que fait chaque analyseur

### Législation (`src/parsers/legislation_parser.mojo`)

Analyse une loi fédérale en `Loi → Article → Paragraphe → Alinéa → Sous-alinéa`, en respectant l'imbrication réelle `1`, `(1)`, `(a)`, `(i)` utilisée en droit fédéral canadien.

- Reconnaît les métadonnées `CHAPTER:`/`TITLE:` et les mentions « Marginal note: », et traite toute ligne non étiquetée en casse de titre comme un titre (les vrais PDF mélangent titres de partie et notes par disposition sans moyen fiable de les distinguer).
- Refusionne le texte de clause à double interligne, réparti sur plusieurs pages, en paragraphes uniques.
- Distingue un véritable nouveau numéro d'article d'un renvoi dans le texte (« under section 41 or 44 ») et d'une citation d'historique de modification en fin de disposition (« 1980-81-82-83, c. 111 ») — deux cas d'échec réels confirmés sur le PDF réel de la *Loi sur l'accès à l'information*.
- Ignore automatiquement les pages liminaires d'une loi (page de titre, table des matières) : la table des matières s'analyse comme une suite d'« articles » qui imite la vraie numérotation, donc l'analyseur rejette tout ce qui précède le redémarrage de la numérotation à 1, et s'arrête au premier saut non croissant qui suit (début d'une annexe/modifications).
- L'extraction du PDF est recadrée sur la moitié gauche de la page, car Justice Laws présente l'anglais et le français en deux colonnes côte à côte sur chaque page.

### Jurisprudence (`src/parsers/jurisprudence_parser.mojo`)

Analyse un ou plusieurs jugements en paragraphes numérotés `[1]`, `[2]`, ..., avec des titres de style `I.`/`A.` — aussi bien pour les tribunaux anglophones que pour les tribunaux québécois (francophones).

- Accepte les étiquettes d'en-tête en anglais et en français (`STYLE OF CAUSE:`/`INTITULÉ:`, `COURT:`/`COUR:`, `DOCKET:`/`DOSSIER:`, ...).
- Élimine la page de couverture de chaque jugement en avançant jusqu'au premier `[1]` exact — les vraies pages de couverture (bloc de titre, liste des parties, formation) n'ont aucune mise en page commune d'un tribunal à l'autre, donc il n'y a pas d'autre point d'ancrage fiable.
- Exige que les marqueurs de paragraphe et de titre correspondent *exactement* au numéro/à la lettre suivant attendu, ce qui empêche une citation dans le texte comme `[1995] 3 R.C.S. 453` d'être lue à tort comme le paragraphe `[1995]`.
- `Document <- Jugement+` : un même fichier peut contenir plusieurs jugements concaténés sans séparateur, et la grammaire les distingue à l'endroit où le corps d'un jugement cesse d'être bien formé et où les pages liminaires du suivant commencent.

### Doctrine (`src/parsers/doctrine_parser.mojo`)

Analyse la doctrine juridique — articles de revue, chapitres de traités, commentaires d'arrêts — en un en-tête titre/auteur/citation, des titres romains/lettrés/simples (repris de la grammaire de jurisprudence, puisque les vrais articles suivent la même convention), un texte suivi et un appareil de notes de bas de page numérotées séquentiellement.

- Reconnaît les métadonnées `TITLE:`/`TITRE:`, `AUTHOR:`/`AUTEUR:`/`AUTEURE:`, `SOURCE:`, `YEAR:`/`ANNÉE:`, avec un repli sur un titre implicite en l'absence d'étiquette `TITRE:`.
- Distingue une note de bas de page (« 12. Voir Côté, ... ») du texte courant en exigeant que le numéro corresponde exactement à la prochaine note attendue, la même astuce anti-ambiguïté que celle utilisée pour les numéros de paragraphe en jurisprudence.

### Conventions communes

Les trois analyseurs partagent une seule interface, donc passer de l'un à l'autre revient à changer d'exécutable :

```
mojo run <parser>.mojo [file] [--export|--out|-o <path>]
```

- **Aucun fichier fourni** → analyse un exemple illustratif intégré (pratique pour un test rapide).
- **`.pdf`** → appelle `pdftotext -layout` (de `poppler-utils`) et normalise les sauts de page ; **`.txt`** → lu directement. Toute autre extension est rejetée plutôt que devinée silencieusement.
- **`--export`/`--out`/`-o`** écrit le résultat rendu dans un fichier plutôt que sur la sortie standard — voir `output/*.txt` pour des exemples réels produits ainsi.
- L'extraction PDF se fait au mieux : les vrais PDF de lois/jugements/articles comportent des en-têtes, pieds de page et bandeaux de numéro de page récurrents qui ne sont pas toujours entièrement retirés, d'où un nettoyage manuel parfois nécessaire.

## Jeux de test — voir le résultat concret

`src/testdata/` contient un vrai PDF non modifié par analyseur (les mêmes fichiers utilisés par les tests d'intégration et les benchmarks), plus un ensemble de fixtures `.txt` écrites à la main — organisées dans les trois mêmes dossiers par type — qui exercent les fonctionnalités de grammaire décrites ci-dessus sans avoir besoin de `pdftotext`. Aucune des fixtures `.txt` n'est une transcription d'un document réel ; elles sont modelées sur les conventions de mise en forme réelles, de la même façon que l'exemple intégré de chaque analyseur.

```
src/testdata/legislation/     access_to_information_act.pdf (réel)  + 7 fixtures .txt
src/testdata/jurisprudence/   poonian_v_bc_securities_2024scc28.pdf (réel) + 7 fixtures .txt
src/testdata/doctrine/        mlj_readability_deficits.pdf (réel)  + 6 fixtures .txt
```

Les fixtures de chaque dossier couvrent un aspect différent de la grammaire de cet analyseur — imbrication profonde `(a)(i)(ii)`, numéros d'article fractionnaires, titres de Partie/Section empilés, pages de couverture chargées en pages liminaires, mélanges de titres romains/lettrés/simples, notes de bas de page séquentielles, texte bilingue (accentué en français), et plusieurs documents concaténés dans un seul fichier sans séparateur. Voir les noms de fichiers de chaque dossier pour savoir ce que chacun cible.

Il y a deux façons d'exécuter l'ensemble du dossier, à deux niveaux différents :

**Depuis le terminal, pour un aperçu rapide du résultat réel.** `scripts/dev.sh smoke` appelle chaque analyseur une fois par fichier et rapporte le succès/échec par fichier :

```bash
scripts/dev.sh smoke                 # les trois analyseurs sur toutes leurs fixtures
scripts/dev.sh smoke jurisprudence   # un seul
```

(ou les tâches « Smoke: ... » depuis l'exécuteur de tâches de VS Code). C'est la façon la plus rapide de voir réellement l'analyseur fonctionner de bout en bout sur plus de 20 documents, et d'examiner le résultat rendu d'un fichier (`scripts/dev.sh parse <parser> <path>`) plutôt que de se fier uniquement aux assertions des tests unitaires.

**Dans le cadre de la suite de tests automatisés, pour la couverture CI/régression.** Chaque fichier `src/tests/integration/test_<parser>_integration.mojo` possède, en plus de son test unique et minutieusement vérifié sur un vrai PDF, un test `test_all_testdata_fixtures_parse` qui liste `src/testdata/<parser>/` à l'exécution (via `std.os.listdir`) et vérifie que chaque fichier s'analyse sans lever d'erreur — en recueillant les échecs avec leurs messages d'erreur plutôt que de s'arrêter au premier. Il s'exécute partout où le reste de la suite s'exécute :

```bash
scripts/dev.sh test integration            # inclut ce test pour les trois analyseurs
pixi run test-legislation-integration      # ou seulement la suite d'intégration d'un analyseur
```

Comme il liste le dossier plutôt que de nommer les fichiers, déposer une nouvelle fixture dans `src/testdata/<parser>/` la fait automatiquement couvrir — aucune modification de code de test nécessaire.

## Structure du projet

```
src/
  parsers/         Les trois analyseurs (également exécutables directement)
  tests/unit/       Tests rapides, sans E/S, sur des fixtures écrites à la main
  tests/integration/  Tests qui analysent les vrais PDF dans src/testdata/<type>/
  benchmarks/       Benchmarks de temps d'exécution pour chaque analyseur
  testdata/
    legislation/    Exemples de lois à analyser — 1 vrai PDF + 7 fixtures .txt synthétiques
    jurisprudence/  Exemples de jugements à analyser — 1 vrai PDF + 7 fixtures .txt synthétiques
    doctrine/       Exemples d'articles à analyser — 1 vrai PDF + 6 fixtures .txt synthétiques
output/             Exemples de sortie des analyseurs (générés via --export)
scripts/dev.sh      Enveloppe CLI conviviale autour des tâches pixi ci-dessous
.vscode/            Tâches VS Code pour les mêmes opérations, via la palette de commandes → Run Task
```

## Pour commencer

### 1. Installer Mojo (via `pixi`)

Ce projet n'a pas besoin d'une installation séparée de Mojo : [`pixi`](https://pixi.sh) est le gestionnaire de paquets, et la section `[dependencies]` de `pixi.toml` récupère le compilateur `mojo` lui-même depuis le canal conda de Modular — installer le projet, c'est installer Mojo, épinglé à la version sur laquelle ce dépôt a été construit.

1. Installez `pixi` lui-même, si ce n'est déjà fait :
   ```bash
   curl -fsSL https://pixi.sh/install.sh | sh
   ```
   (voir [pixi.sh](https://pixi.sh) pour les autres plateformes/méthodes.) Redémarrez votre shell, ou rechargez son fichier de configuration, pour que `pixi` soit sur le `PATH`.
2. Depuis la racine du projet, installez l'environnement (cela télécharge Mojo et la plateforme MAX dans un dossier local `.pixi/` ignoré par git — rien n'est installé au niveau du système) :
   ```bash
   pixi install
   ```
3. Vérifiez que ça a fonctionné :
   ```bash
   pixi run mojo --version
   ```

> **Windows (via WSL2) :** Mojo n'a pas de version native pour Windows, et le `pixi.toml` de ce dépôt ne déclare que `platforms = ["linux-64"]`, donc `pixi install` échouera sous Windows nu (PowerShell/cmd). Installez [WSL2](https://learn.microsoft.com/fr-fr/windows/wsl/install) avec une distribution Ubuntu, puis exécutez les étapes ci-dessus (`pixi install`, `scripts/dev.sh`, etc.) depuis le shell WSL — tout fonctionne là exactement comme sous Linux natif.

Pour l'entrée PDF en particulier (les trois analyseurs acceptent `.pdf` ou `.txt`), il vous faudra aussi `pdftotext` — de `poppler-utils` — sur le `PATH` de votre système :

```bash
# Debian/Ubuntu
sudo apt install poppler-utils
# macOS
brew install poppler
```

Une entrée `.txt` (y compris chaque fixture synthétique sous `src/testdata/`) ne nécessite aucune dépendance supplémentaire.

> **Si vous déplacez ou renommez ce dossier de projet**, supprimez `.pixi/` et relancez `pixi install` : l'environnement met en cache certains chemins absolus à l'installation, et un cache périmé après un déplacement se manifeste par un `mojo` incapable de trouver sa propre bibliothèque standard (« unable to locate module 'std' ») ou son runtime de compilation.

### 2. Lancer quelque chose

```bash
scripts/dev.sh parse doctrine src/testdata/doctrine/01_basic_footnotes.txt
scripts/dev.sh test unit doctrine       # tests unitaires d'un seul analyseur
scripts/dev.sh test unit               # tests unitaires des trois analyseurs
scripts/dev.sh test integration        # tests d'intégration sur de vrais PDF
scripts/dev.sh test all                # tout
scripts/dev.sh bench legislation       # benchmark d'un seul analyseur
scripts/dev.sh bench                   # les trois benchmarks
scripts/dev.sh smoke                   # analyse chaque fixture de test, rapporte succès/échec
scripts/dev.sh list                    # affiche les tâches pixi sous-jacentes
```

Ou appelez directement les tâches `pixi` sous-jacentes — `pixi task list` les affiche toutes (`parse-doctrine`, `test-legislation`, `bench-jurisprudence`, `test-all`, ...).

### Depuis VS Code

Ouvrez le dossier, installez l'[extension Mojo](https://marketplace.visualstudio.com/items?itemName=modular-mojotools.vscode-mojo) recommandée lorsqu'elle est proposée, puis **Palette de commandes → « Tasks: Run Task »** pour la même liste (test/bench/smoke par analyseur, ou « Test: all »). Les tâches « Parse » demandent un chemin de fichier, avec par défaut l'exemple correspondant dans `src/testdata/<type>/`.

## Pistes pour la suite

- **Formats d'export structurés.** La sortie actuelle est du texte mis en forme ; un `--format json` (ou similaire) permettrait d'alimenter facilement l'AST analysé dans d'autres outils.
- **Législation provinciale/territoriale.** La grammaire de législation cible spécifiquement la mise en page des lois fédérales de Justice Laws ; les éditeurs de lois provinciales suivent des conventions différentes (bien qu'apparentées).
- **Suppression des en-têtes/pieds de page.** L'extraction PDF se fait au mieux — un détecteur plus général d'en-têtes/pieds de page récurrents (plutôt que les motifs codés en dur actuels) réduirait le nettoyage manuel nécessaire sur de vrais PDF.
- **Résolution des renvois.** Aucun des analyseurs ne résout actuellement les citations (« article 41 », `[1995] 3 R.C.S. 453`, renvois de notes) en liens entre documents — c'est une couche naturelle à ajouter une fois l'analyse d'un seul document bien maîtrisée.
- **Historique des modifications en données structurées.** Les citations d'historique de modification en fin de disposition de la législation (« 1980-81-82-83, c. 111, Ann. I ») ne sont actuellement reconnues que juste assez pour *ne pas* être lues à tort comme de nouveaux articles ; les capturer comme champ à part permettrait aux outils en aval d'afficher l'historique d'une disposition.
- **Un point d'entrée CLI/bibliothèque commun.** Actuellement, chaque analyseur est un fichier exécutable via `mojo run` avec son propre `main()` dupliqué ; à mesure que le projet grandit, un point d'entrée unique de répartition (`mojo run src/cli.mojo parse legislation ...`) ou une véritable surface de paquet/bibliothèque pourrait valoir la peine.
