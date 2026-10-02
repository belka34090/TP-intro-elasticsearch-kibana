# TP1 — Introduction à Elasticsearch

## Exercice 0 — Accès au cluster

Les requêtes envoyées depuis Kibana Dev Tools et `curl` retournent les mêmes informations du cluster : les outils changent, mais ils interrogent la même API REST Elasticsearch.

Sans authentification, Elasticsearch refuse l'accès avec un code HTTP **401 Unauthorized**. Kibana ne redemande pas le mot de passe à chaque requête parce que l'utilisateur est déjà authentifié dans la session Kibana ; Kibana relaie ensuite les appels vers Elasticsearch avec le contexte de cette session.

---

## Partie 1 — Concepts, CRUD et mapping

### Exercice 1.1 — Explorer le cluster

La stack utilisée dans le TP fonctionne avec Elasticsearch **9.5.4** et un seul nœud, `es01`.

Les index dont le nom commence par un point sont des index internes ou cachés utilisés par Elasticsearch/Kibana pour leur propre fonctionnement. Ils ne correspondent pas aux données métier du TP.

### Exercice 1.2 — CRUD

Lors du premier `PUT`, le document est créé avec `_version = 1`. Une mise à jour du même document incrémente ensuite cette version.

Avec `POST essai/_doc` sans identifiant dans l'URL, Elasticsearch génère automatiquement un `_id`.

L'index `essai` n'existait pas avant le premier `PUT` : Elasticsearch l'a créé automatiquement avec un mapping dynamique.

### Exercice 1.3 — Pièges du mapping dynamique

Comme `"45000"` est envoyé comme chaîne de caractères et que la détection numérique n'est pas activée par défaut, `salaire` est mappé comme chaîne, et non comme nombre.

`publication` correspond au format d'une date et peut être détecté comme un champ `date`.

Le second document contenant `52000` est accepté car Elasticsearch peut convertir cette valeur en représentation textuelle pour le champ déjà défini. Le problème est que `salaire` n'est alors pas un vrai champ numérique : les tris, intervalles et agrégations numériques ne se comportent pas comme attendu.

### Exercice 1.4 — Mapping explicite

Le mapping final utilise :

- `keyword` pour `id`, `entreprise`, `ville`, `contrat` et `teletravail` ;
- `text` avec analyseur `french` pour `titre` et `description` ;
- `titre.brut` en `keyword` pour le tri et les facettes ;
- `competences` en `keyword` et `competences.texte` en `text` ;
- `geo_point` pour `localisation` ;
- `integer` pour l'expérience et les salaires ;
- `date` pour `date_publication` ;
- `dynamic: strict` pour refuser les champs imprévus.

L'envoi de `champ_inconnu` est donc rejeté. Ce verrou est utile en production car il empêche qu'une faute de nom ou un champ inattendu modifie silencieusement le schéma de l'index.

---

## Partie 2 — Ingestion en Python

### Exercice 2.1 — `ingest.py`

Le script final :

- lit le NDJSON ligne par ligne avec un générateur ;
- fixe `_id` à partir de l'identifiant métier `id` ;
- sait supprimer/recréer l'index avec `--reset` ;
- utilise `helpers.bulk` par lots de 1 000 ;
- conserve les erreurs avec `raise_on_error=False` ;
- force un refresh avant le comptage.

La validation réelle du TP a donné **5 000 documents indexés et 0 erreur**.

### Exercice 2.2 — Idempotence

Une seconde ingestion ne double pas le nombre de documents : il reste à **5 000**.

La raison est que chaque offre réutilise le même `_id` métier. L'action d'indexation remplace le document existant de même identifiant. Avec des identifiants générés automatiquement par Elasticsearch, une nouvelle ingestion créerait de nouveaux documents et donc des doublons.

### Exercice 2.3 — Erreur de mapping

Le document `OFF-99999` comportant le champ supplémentaire `prime` est rejeté par le mapping `dynamic: strict`.

Le lot complet n'est pas annulé : seul le document invalide échoue. `raise_on_error=False` permet de continuer le traitement du reste du lot et de récupérer les erreurs pour les analyser.

Après le test, le fichier source est régénéré proprement.

### Exercice 2.4 — Kibana

L'index `offres` contient bien **5 000 documents** et peut être parcouru dans Kibana avec une data view `offres`.

---

## Partie 3 — Recherche et analyseurs

### Exercice 3.1 — Analyseur français

L'analyseur `standard` découpe essentiellement le texte et le passe en minuscules.

L'analyseur `french` applique en plus les traitements propres au français : suppression de certains mots très fréquents, élision et racinisation. Des formes proches comme `donnée` et `données` convergent donc vers une forme utile pour la recherche, contrairement à une comparaison exacte sur la chaîne brute.

### Exercice 3.2 — `match` contre `term`

`term` ne passe pas la valeur recherchée dans un analyseur : il compare une valeur exacte.

Ainsi :

- `ville = "paris"` ne correspond pas à la valeur `"Paris"` du champ `keyword` ;
- une requête `term` sur `titre` est inadaptée car `titre` est un champ `text`, donc analysé.

Les corrections sont :

- `term` sur `ville: "Paris"` ;
- `term` sur `titre.brut: "Data Engineer Senior"`.

Avec `operator: "and"`, les deux termes de `"projets bancaires"` doivent être présents, donc le nombre de résultats devient inférieur ou égal à celui de la recherche par défaut en OR.

### Exercice 3.3 — Faute et pondération

Le paramètre `fuzziness: "AUTO"` permet de rattraper la faute dans `kubernetis`.

La pondération `titre^3` augmente le poids du titre dans le score. Les documents dont le titre correspond fortement remontent donc dans le classement.

### Exercice 3.4 — Requête booléenne

Les critères exacts sont placés dans `filter` car :

1. ils ne doivent pas influencer le score de pertinence ;
2. Elasticsearch peut optimiser et mettre en cache ce type de filtre.

Le bloc `should` sur `Elasticsearch` n'exclut pas les autres documents ; il augmente le score des documents possédant cette compétence.

### Exercice 3.5 — Géolocalisation

La requête `geo_distance` sélectionne les offres situées à moins de 20 km de Montpellier et le tri `_geo_distance` les ordonne de la plus proche à la plus lointaine.

### Exercice 3.6 — Pagination et surlignage

Pour une page 2 de taille 5, `from = 5` et `size = 5`.

`from + size` est limité à 10 000 résultats par défaut afin d'éviter le coût important d'une pagination profonde. Au-delà, Elasticsearch recommande `search_after`, idéalement avec un **PIT** (*Point In Time*, vue cohérente des résultats pendant la pagination).

---

## Partie 4 — Agrégations

### Exercice 4.1 — Salaire moyen par ville

Sur le jeu déterministe du TP, **Paris** possède le salaire minimum moyen le plus élevé, environ **57 442 €**.

La moyenne n'est calculée que sur les offres qui possèdent réellement `salaire_min`, soit **3 389 offres** sur 5 000.

Une agrégation `terms` directement sur `titre` échoue car `titre` est de type `text`. Il faut utiliser le sous-champ `titre.brut`, de type `keyword`.

### Exercice 4.2 — Publications par mois

Le `date_histogram` produit les volumes suivants :

| Mois | Offres |
| --- | ---: |
| 2026-04 | 763 |
| 2026-05 | 865 |
| 2026-06 | 820 |
| 2026-07 | 835 |
| 2026-08 | 880 |
| 2026-09 | 837 |

Chaque mois peut ensuite être ventilé par `contrat` avec une sous-agrégation `terms`.

### Exercice 4.3 — Tranches de salaire

Sur les offres disposant de `salaire_min` :

| Tranche | Offres |
| --- | ---: |
| < 40 k€ | 484 |
| 40–55 k€ | 1 363 |
| ≥ 55 k€ | 1 542 |

Pour `experience_annees`, les valeurs vont de **0 à 15 ans**, avec une moyenne d'environ **5,91 ans**.

### Exercice 4.4 — Data Engineer

En ciblant les titres `Data Engineer`, le jeu généré contient **462 offres**.

Les cinq compétences les plus fréquentes sont :

| Compétence | Occurrences |
| --- | ---: |
| Airflow | 315 |
| Spark | 313 |
| Kafka | 312 |
| Python | 311 |
| SQL | 301 |

Le télétravail le plus fréquent est `partiel` avec **284 offres**.

Les agrégations s'appliquent uniquement aux documents sélectionnés par la requête, pas à tout l'index.

---

## Mini-défi — `search.py`

Le moteur de recherche en ligne de commande est complété avec :

- recherche `multi_match` pondérée et tolérante aux fautes ;
- filtres optionnels ville, contrat, télétravail et salaire ;
- filtre géographique ;
- pagination ;
- surlignage de la description ;
- facettes par ville, contrat et compétence.

---
