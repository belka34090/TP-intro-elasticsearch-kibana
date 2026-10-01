# TP2 — Logstash

## Mise en place

### Pourquoi ne pas utiliser le compte `elastic` pour Logstash ?

Le compte `elastic` est un super-utilisateur. Logstash n'a besoin que d'écrire dans `offres` et `logs-web-*`, et de quelques droits de supervision/configuration. Le compte dédié `logstash_internal` respecte donc le principe du moindre privilège : en cas de fuite du secret ou de compromission du service, les droits disponibles restent limités.

### Que se passerait-il si le pipeline `web` écrivait dans `logs-generic-default` ?

Le rôle `logstash_writer` n'autorise que `offres` et `logs-web-*`. Une écriture dans `logs-generic-default` serait donc refusée par Elasticsearch avec une erreur d'autorisation, typiquement HTTP 403.

### Pourquoi transmettre le mot de passe par variable d'environnement ?

Le mot de passe n'est pas écrit dans les fichiers `.conf` versionnés. Il reste dans `.env`, lui-même ignoré par Git. Cela évite d'exposer un secret dans le dépôt.

---

## Exercice 0 — Premier pipeline

### Quels champs Logstash ajoute-t-il ?

Le test au clavier a montré les champs suivants :

- `message` : contenu courant de l'événement ;
- `@timestamp` : date et heure de création/réception de l'événement ;
- `@version` : version interne de l'événement Logstash ;
- `event.original` : contenu original avant transformation ;
- `host.hostname` : nom du conteneur Logstash.

### Que contient `@timestamp` ?

Dans ce test, `@timestamp` correspond au moment où Logstash reçoit et crée l'événement. Il est enregistré en UTC.

### Que fait le filtre `uppercase` ?

Le filtre `mutate` transforme `message` en majuscules. Ainsi, `bonjour logstash` devient `BONJOUR LOGSTASH`, tandis que `event.original` conserve la valeur d'origine.

### À quoi sert `--path.data /tmp/essai` ?

`path.data` est le répertoire de travail interne de Logstash. Utiliser `/tmp/essai` isole le Logstash temporaire du service principal et évite que deux instances utilisent simultanément le même répertoire.

---

# Partie 1 — Recharger les offres avec Logstash

## Exercice 1.1 — Pipeline `offres`

Le pipeline lit `/data/offres*.ndjson` en mode `read`, décode chaque ligne en JSON, désactive la mémoire `sincedb` pour le laboratoire et conserve les fichiers après lecture.

La sortie utilise :

- `index => "offres"` ;
- `document_id => "%{id}"` ;
- `action => "index"` ;
- `data_stream => "false"` ;
- `manage_template => false`.

L'identifiant métier devient donc l'`_id` Elasticsearch. Une même offre réindexée remplace le document de même identifiant au lieu de créer un doublon.

La validation de syntaxe a été effectuée avec succès : `Config Validation Result: OK`.

## Exercice 1.2 — Premier lancement sans correction

Avant Logstash, les 5 000 offres créées par `ingest.py --reset` ont un `_version` initial de 1.

Sans filtre de nettoyage, Logstash ajoute notamment `@timestamp`, `@version`, `event.original`, `host.*` et `log.*`. Le mapping de `offres` étant en `dynamic: strict`, ces champs non déclarés sont refusés.

Le rejet se fait au niveau du document dans l'API Bulk avec un statut HTTP 400. L'erreur est une erreur de parsing de document dont la cause est un mapping dynamique strict : Elasticsearch refuse le premier champ inconnu rencontré.

Conséquence : les documents rejetés ne remplacent pas les documents existants.

## Exercice 1.3 — Correction

Le filtre final supprime les champs techniques :

```text
@timestamp
@version
event
host
log
```

Après correction, les 5 000 documents sont réindexés dans `offres`. Le nombre reste 5 000 car `document_id => "%{id}"` réutilise le même `_id`.

La version de `OFF-00002` passe alors de 1 à 2 : le document existant a été remplacé une fois.

Il est préférable de supprimer les champs techniques plutôt que d'assouplir le mapping, car l'index `offres` représente des entités métier avec un schéma maîtrisé. Autoriser des champs dynamiques ferait perdre ce contrôle.

L'index doit exister avant Logstash parce que `manage_template => false` interdit à Logstash d'installer un modèle de mapping. Si Elasticsearch créait automatiquement l'index au premier document, son mapping ne serait pas celui défini dans le TP d'introduction.

## Exercice 1.4 — Relance

Avec `sincedb_path => "/dev/null"`, Logstash ne mémorise pas la position de lecture. Le fichier est donc relu à chaque démarrage.

Une nouvelle relance réindexe les mêmes 5 000 `_id` : le nombre de documents reste 5 000 et `_version` augmente à nouveau, par exemple de 2 à 3.

Avec la `sincedb` par défaut, Logstash se souviendrait que le fichier a déjà été lu et ne le rejouerait normalement pas.

Sans `document_id`, Elasticsearch générerait un nouvel `_id` à chaque lecture et les relances créeraient des doublons.

---

# Partie 2 — Superviser et fiabiliser

## Exercice 2.1 — Supervision

`pipelines.yml` déclare deux pipelines isolés :

- `offres` ;
- `web`.

La supervision réelle du service confirme **deux pipelines**, `offres` et `web`, avec **32 workers chacun**. Le statut global de Logstash est `green` et la DLQ est activée pour les deux pipelines.

Pour `offres`, les compteurs observés depuis le dernier démarrage sont :

- `in = 5000` ;
- `filtered = 5000` ;
- `out = 5000`.

Ils représentent respectivement les événements reçus, passés dans les filtres et transmis à la sortie.

Le plugin qui consomme le plus de temps est la sortie **Elasticsearch** avec **36 695 ms**, contre **3 623 ms** pour le filtre `mutate`. C'est cohérent : l'envoi réseau et l'indexation des documents coûtent davantage que la suppression de quelques champs.

## Exercice 2.2 — Dead Letter Queue

La DLQ, ou *Dead Letter Queue*, est activée dans le service Logstash final.

Le document de test `OFF-99999` contient un champ supplémentaire `prime`. La vérification réelle confirme qu'il est **absent de l'index** et que `offres` reste à **5 000 documents**.

Elasticsearch renvoie un statut **HTTP 400** avec l'exception :

```text
strict_dynamic_mapping_exception
```

et la raison :

```text
mapping set to strict, dynamic introduction of [prime] within [_doc] is not allowed
```

Logstash route bien cet événement vers la DLQ. Un fichier `dead_letter_queue/offres/1.log` de **2 164 octets** a été créé, ce qui confirme que le document rejeté a été conservé sur disque.

Par rapport à `raise_on_error=False` dans `ingest.py`, la DLQ apporte une conservation durable du document rejeté et de son contexte, ce qui permet de l'analyser et de le rejouer plus tard.

Réinjection en trois étapes :

1. lire la DLQ et identifier la cause du rejet ;
2. corriger le document ou le mapping selon le besoin métier ;
3. renvoyer le document corrigé vers Elasticsearch puis valider sa présence.

## Exercice 2.3 — Pourquoi deux pipelines ?

Sans `pipelines.yml`, les fichiers `.conf` du dossier seraient concaténés dans un seul pipeline `main`.

Dans ce cas, une offre lue par l'entrée `offres` traverserait aussi les filtres du pipeline web et serait envoyée vers toutes les sorties, y compris le data stream web. Inversement, une ligne de log web pourrait être envoyée vers l'index `offres`, où son schéma serait refusé.

L'isolation apporte également :

- des compteurs et une supervision séparés ;
- une panne ou une modification d'un flux plus facile à diagnostiquer sans mélanger les traitements.

## Exercice 2.4 — Ne rien perdre

La supervision réelle indique `queue.type = "memory"`. Avec cette file en mémoire, un arrêt brutal peut perdre les événements déjà lus mais pas encore transmis.

Le réglage `queue.type: persisted` utilise une file persistée sur disque. Après redémarrage, Logstash peut reprendre les événements non acquittés. La garantie devient « au moins une fois » : un événement peut être rejoué.

Le `document_id` métier devient alors important pour `offres`, car une éventuelle répétition remplace le même document au lieu de créer un doublon.

---

# Partie 3 — Transformer les logs d'accès

## Exercice 3.1 — Génération

Le générateur déterministe avec le seed 42 produit exactement 20 700 lignes couvrant sept jours, du 23/09/2026 au 29/09/2026 inclus.

## Exercice 3.2 — Motif Grok

`%{COMBINEDAPACHELOG}` extrait notamment :

- `source.address` ;
- `timestamp` ;
- `http.request.method` ;
- `url.original` ;
- `http.version` ;
- `http.response.status_code` ;
- `http.response.body.bytes` ;
- `http.request.referrer` ;
- `user_agent.original`.

Avec les motifs ECS utilisés par Logstash, `http.response.status_code` est converti en entier.

Le champ `timestamp` doit encore être traité par le filtre `date` afin que `@timestamp` contienne la date réelle de la requête et non l'heure à laquelle Logstash a lu la ligne.

L'identifiant d'offre est extrait avec un motif de type :

```text
OFFRE_ID = OFF-[0-9]{5}
```

puis stocké dans `labels.offre_id`.

## Exercice 3.3 — `web.conf`

Le pipeline final :

1. lit `/data/access.log` ;
2. découpe la ligne Apache avec `grok` ;
3. convertit la date avec `date` ;
4. analyse le navigateur avec `useragent` ;
5. extrait `labels.offre_id` pour les URL d'offres ;
6. écrit dans le data stream `logs-web-default`.

## Exercice 3.4 — Vérifications

Valeurs déterministes vérifiées après une ingestion propre :

- documents : **20 700** ;
- échecs `_grokparsefailure` : **0** ;
- premier événement : **23/09/2026 00:00:39 +02:00**, soit **22/09/2026 22:00:39 UTC** ;
- `http.response.status_code` : type entier ;
- `index.mode` : `logsdb`.

Le backing index observé est :

```text
.ds-logs-web-default-2026.10.01-000001
```

C'est l'index caché qui contient physiquement les documents du data stream. Le data stream utilise bien le mode `logsdb` et la stratégie ILM `logs`.

## Exercice 3.5 — Rejouer sans doublon

Comme `sincedb_path => "/dev/null"` force la relecture et qu'aucun `document_id` stable n'est défini pour les logs, un second passage ajoute à nouveau les 20 700 événements.

La vérification réelle donne :

```text
Avant redémarrage : 20700
Après redémarrage : 41400
```

Le doublement est donc confirmé expérimentalement.

Le problème ne se posait pas pour `offres`, car chaque offre utilisait son identifiant métier comme `_id`.

Un data stream est conçu pour des événements en ajout. Pour rendre le rejeu sûr, deux approches possibles sont :

- conserver une `sincedb` normale afin de ne pas relire un fichier déjà consommé ;
- calculer un identifiant déterministe avec le filtre `fingerprint` et l'utiliser comme identifiant du document afin de détecter les événements déjà vus.

---

# Partie 4 — Enquête Kibana

Les résultats ci-dessous proviennent du jeu de données déterministe fourni par le TP, seed 42.

## Exercice 4.1 — Vue d'ensemble

Répartition par code HTTP :

| Code | Requêtes |
| ---: | ---: |
| 200 | 17 805 |
| 201 | 1 492 |
| 304 | 488 |
| 404 | 508 |
| 500 | 5 |
| 503 | 402 |

Répartition par méthode :

| Méthode | Requêtes |
| --- | ---: |
| GET | 19 208 |
| POST | 1 492 |

Le volume total est de 20 700 requêtes sur 7 jours, soit une moyenne de **2 957,14 requêtes par jour**.

Volumes journaliers :

| Jour | Requêtes |
| --- | ---: |
| 23/09 | 2 832 |
| 24/09 | 2 884 |
| 25/09 | 2 843 |
| 26/09 | 3 122 |
| 27/09 | 2 903 |
| 28/09 | 3 274 |
| 29/09 | 2 842 |

## Exercice 4.2 — Incident

L'incident principal a lieu le **28 septembre 2026 entre 14:00 et 14:45 heure France**.

Les 503 apparaissent de **14:00:08 à 14:44:56**, soit environ 45 minutes.

Nombre de réponses 503 : **402**.

Répartition par tranches de cinq minutes :

| Tranche | 503 |
| --- | ---: |
| 14:00 | 53 |
| 14:05 | 41 |
| 14:10 | 42 |
| 14:15 | 35 |
| 14:20 | 44 |
| 14:25 | 42 |
| 14:30 | 50 |
| 14:35 | 47 |
| 14:40 | 48 |

Les erreurs touchent uniquement `/api/offres`. Les pages d'accueil, de recherche, les pages d'offres et les fichiers statiques ne présentent pas cette rafale de 503.

Pendant cette fenêtre, l'API reçoit **403 requêtes**, contre seulement 4 à 15 sur la même tranche horaire les autres jours. Le jeu de données simule explicitement des réessais clients : l'augmentation du trafic est donc cohérente avec des clients qui retentent leurs appels pendant l'indisponibilité.

## Exercice 4.3 — Activité suspecte

L'adresse IP responsable de la rafale de 404 est :

```text
203.0.113.66
```

Elle génère **300 requêtes 404** entre **03:12:00 et 03:16:59 le 26/09/2026**, soit environ cinq minutes.

Chemins recherchés :

| URL | Requêtes |
| --- | ---: |
| `/admin` | 59 |
| `/.git/config` | 55 |
| `/.env` | 53 |
| `/phpmyadmin/` | 46 |
| `/server-status` | 44 |
| `/wp-login.php` | 43 |

Son User-Agent est :

```text
Mozilla/5.0 zgrab/0.x
```

`zgrab` est un outil automatisé de scan ; ce comportement, combiné aux chemins sensibles recherchés et à la cadence d'une requête par seconde, le distingue d'une navigation humaine classique.

Il reste **208 autres 404**. Elles concernent des URL d'offres inexistantes et sont réparties entre de nombreuses IP et des navigateurs classiques. Elles ressemblent donc davantage à des liens invalides ou des identifiants d'offres inexistants qu'au scan concentré du robot.

## Exercice 4.4 — Offres les plus consultées

Avec un tri secondaire sur l'identifiant pour rendre les égalités déterministes :

| Rang | Offre | Consultations | Titre | Ville | Contrat |
| ---: | --- | ---: | --- | --- | --- |
| 1 | OFF-04662 | 8 | Développeur Front-end Senior | Bordeaux | Freelance |
| 2 | OFF-01153 | 7 | Développeur Java Confirmé | Toulouse | Freelance |
| 3 | OFF-03141 | 7 | Développeur Python Confirmé | Bordeaux | CDI |
| 4 | OFF-00289 | 6 | Data Scientist Lead | Lyon | CDI |
| 5 | OFF-00901 | 6 | Développeur Java Junior | Paris | CDI |
| 6 | OFF-01275 | 6 | Administrateur Bases de Données Lead | Paris | CDI |
| 7 | OFF-01660 | 6 | Architecte Cloud Senior | Lyon | CDI |
| 8 | OFF-02899 | 6 | Data Engineer (Alternance) | Lyon | Alternance |
| 9 | OFF-03126 | 6 | Administrateur Bases de Données Junior | Lyon | CDI |
| 10 | OFF-03145 | 6 | Data Engineer Lead | Montpellier | CDI |

Plusieurs offres sont à égalité avec six consultations ; le tri secondaire par `labels.offre_id` fixe donc l'ordre du Top 10.

## Exercice 4.5 — Public

Les agents mobiles Android et iPhone représentent **8 155 requêtes sur 20 700**, soit **39,4 % du trafic**.

Répartition brute des User-Agents générés :

- Safari macOS : 4 150 ;
- Safari iPhone : 4 099 ;
- Chrome Windows : 4 058 ;
- Chrome Android : 4 056 ;
- Firefox Linux : 4 037 ;
- zgrab : 300.

Le dashboard Kibana confirme les libellés réellement produits par le filtre `useragent` :

- Safari : **20,34 %** ;
- Mobile Safari : **20,09 %** ;
- Chrome : **19,89 %** ;
- Chrome Mobile : **19,88 %** ;
- Firefox : **19,79 %**.

Le robot `zgrab` représente le reliquat très faible hors Top 5.

---

# Partie 5 — Tableau de bord

Le tableau de bord **« Site de recrutement — trafic »** a été créé via l'API Kibana. La réponse HTTP **201** confirme sa création et l'API de lecture retourne bien les cinq panneaux automatisables :

- indicateur du nombre total de requêtes ;
- indicateur du taux de réponses 5xx ;
- trafic dans le temps ventilé par code HTTP ;
- Top 10 des `labels.offre_id` ;
- anneau des navigateurs.

La capture de contrôle montre que les cinq panneaux API sont correctement rendus avec **20 700 requêtes** et un **taux 5xx de 1,97 %**. La carte Kibana Maps utilisant la data view `offres` et le champ `localisation` a également été ajoutée : le dashboard final contient donc les **six panneaux demandés**.

Sur le jeu de données propre, le taux global de réponses 5xx est :

```text
(402 + 5) / 20 700 = 1,97 %
```

Un clic sur une série `503` doit filtrer les autres panneaux du tableau de bord.

La capture finale doit être enregistrée sous :

```text
captures/tableau-de-bord.png
```

## Bonus — Alerte

Une règle « plus de 50 réponses 5xx en 5 minutes » ne se déclenche pas sur ces données historiques si elle vérifie uniquement la période récente. Pour la tester, il faut soit rejouer/générer des événements avec des timestamps actuels, soit adapter temporairement les données de test afin que les événements tombent dans la fenêtre temporelle surveillée.
