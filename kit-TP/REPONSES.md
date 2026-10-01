# TP2 — Logstash

## Exercice 0 — Premier pipeline

### Quels champs Logstash ajoute-t-il ?

Pour le message saisi au clavier, Logstash crée le champ `message` et ajoute notamment :

- `@timestamp` : date et heure de création/réception de l'événement ;
- `@version` : version interne de l'événement Logstash ;
- `event.original` : contenu original avant transformation ;
- `host.hostname` : nom du conteneur Logstash ayant traité l'événement.

### Que contient `@timestamp` ?

`@timestamp` correspond au moment où Logstash reçoit et crée l'événement. Il est enregistré en UTC.

### Que fait le filtre `uppercase` ?

Le filtre `mutate` avec `uppercase` transforme le champ `message` en majuscules.

Ainsi :

`bonjour logstash`

devient :

`BONJOUR LOGSTASH`

Le champ `event.original` conserve toutefois le texte d'origine.

### À quoi sert `--path.data /tmp/essai` ?

`path.data` désigne le répertoire utilisé par Logstash pour ses données techniques internes.

L'utilisation de `/tmp/essai` permet d'isoler ce Logstash temporaire du service Logstash principal et évite que deux instances utilisent le même répertoire de données.
