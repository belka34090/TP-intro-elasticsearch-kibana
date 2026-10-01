# Tableau de bord Kibana — Site de recrutement — trafic

Objectif : produire le livrable final `captures/tableau-de-bord.png`.

## Data views

Créer si nécessaire :

- `Logs web` sur `logs-web-*`, champ temporel `@timestamp` ;
- `offres` sur l'index `offres`.

Pour les logs, utiliser une période absolue couvrant le 23/09/2026 au 30/09/2026.

## Panneaux Lens

### 1. Requêtes

Type : indicateur.

Métrique : nombre de documents.

Valeur attendue sur le jeu propre : **20 700**.

### 2. Taux d'erreur serveur

Type : indicateur.

Formule :

```text
count(kql='http.response.status_code >= 500') / count()
```

Format : pourcentage.

Valeur attendue : environ **1,97 %**.

### 3. Trafic dans le temps

Type : barres empilées.

- axe horizontal : `@timestamp` ;
- métrique : nombre de documents ;
- ventilation : `http.response.status_code`.

Le pic de 503 doit être visible le 28/09/2026 vers 14:00–14:45 heure locale.

### 4. Offres les plus consultées

Type : tableau.

- ligne : `labels.offre_id` ;
- métrique : nombre de documents ;
- taille : Top 10.

Filtrer ce panneau avec :

```text
http.request.method: "GET" and http.response.status_code: 200
```

### 5. Navigateurs

Type : anneau.

- catégorie : `user_agent.name` ;
- métrique : nombre de documents ;
- Top 5.

### 6. Offres par ville

Type : carte.

Utiliser la data view `offres` et le champ géographique `localisation`.

## Vérification d'interactivité

Cliquer sur la série correspondant au code `503` dans le graphique temporel.

Le filtre doit se répercuter sur les autres panneaux du tableau de bord.

## Capture

Enregistrer le tableau de bord sous le nom :

```text
Site de recrutement — trafic
```

Puis enregistrer une capture d'écran complète dans :

```text
captures/tableau-de-bord.png
```
