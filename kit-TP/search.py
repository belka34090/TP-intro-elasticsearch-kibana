"""Mini-défi — moteur de recherche d'offres en ligne de commande.

Exemples :
  python search.py "développeur python"
  python search.py "données spark" --ville Lyon --contrat CDI --salaire-min 45000
  python search.py "kubernetes" --autour "43.6108,3.8767" --rayon 50km --teletravail partiel
"""

from __future__ import annotations

import argparse

from es_client import INDEX, get_client


def construire_requete(args: argparse.Namespace) -> dict:
    """Construit la requête bool à partir du texte et des filtres CLI."""
    filtres: list[dict] = []

    if args.ville:
        filtres.append({"term": {"ville": args.ville}})

    if args.contrat:
        filtres.append({"term": {"contrat": args.contrat}})

    if args.teletravail:
        filtres.append({"term": {"teletravail": args.teletravail}})

    if args.salaire_min is not None:
        filtres.append({"range": {"salaire_max": {"gte": args.salaire_min}}})

    if args.autour:
        try:
            latitude, longitude = (float(v.strip()) for v in args.autour.split(",", 1))
        except (ValueError, TypeError) as exc:
            raise ValueError("--autour doit être au format lat,lon") from exc

        filtres.append({
            "geo_distance": {
                "distance": args.rayon,
                "localisation": {
                    "lat": latitude,
                    "lon": longitude,
                },
            }
        })

    return {
        "bool": {
            "must": [
                {
                    "multi_match": {
                        "query": args.texte,
                        "fields": [
                            "titre^3",
                            "competences.texte^2",
                            "description",
                        ],
                        "fuzziness": "AUTO",
                    }
                }
            ],
            "filter": filtres,
        }
    }


def afficher_facette(nom: str, buckets: list[dict]) -> None:
    print(f"\n{nom} :")
    for bucket in buckets:
        print(f"  - {bucket['key']}: {bucket['doc_count']}")


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("texte")
    parser.add_argument("--ville")
    parser.add_argument(
        "--contrat",
        choices=["CDI", "CDD", "Alternance", "Freelance", "Stage"],
    )
    parser.add_argument(
        "--teletravail",
        choices=["aucun", "partiel", "total"],
    )
    parser.add_argument("--salaire-min", type=int)
    parser.add_argument("--autour", help="lat,lon")
    parser.add_argument("--rayon", default="30km")
    parser.add_argument("--page", type=int, default=1)
    parser.add_argument("--taille", type=int, default=10)
    args = parser.parse_args()

    if args.page < 1:
        parser.error("--page doit être supérieur ou égal à 1")
    if args.taille < 1:
        parser.error("--taille doit être supérieur ou égal à 1")

    try:
        query = construire_requete(args)
    except ValueError as exc:
        parser.error(str(exc))

    es = get_client()
    debut = (args.page - 1) * args.taille

    reponse = es.search(
        index=INDEX,
        query=query,
        from_=debut,
        size=args.taille,
        track_total_hits=True,
        source=[
            "titre",
            "entreprise",
            "ville",
            "contrat",
            "salaire_min",
            "salaire_max",
        ],
        highlight={
            "fields": {
                "description": {}
            }
        },
        aggregations={
            "villes": {
                "terms": {
                    "field": "ville",
                    "size": 12,
                }
            },
            "contrats": {
                "terms": {
                    "field": "contrat",
                    "size": 5,
                }
            },
            "competences": {
                "terms": {
                    "field": "competences",
                    "size": 10,
                }
            },
        },
    )

    total = reponse["hits"]["total"]["value"]
    print(f"{total} résultat(s) — page {args.page}")

    for hit in reponse["hits"]["hits"]:
        source = hit["_source"]
        salaire_min = source.get("salaire_min")
        salaire_max = source.get("salaire_max")

        if salaire_min is None or salaire_max is None:
            salaire = "non renseigné"
        else:
            salaire = f"{salaire_min:,}–{salaire_max:,} €".replace(",", " ")

        extraits = hit.get("highlight", {}).get("description", [])
        extrait = " … ".join(extraits) if extraits else "(aucun extrait)"

        print(
            f"\n[{hit.get('_score', 0):.2f}] "
            f"{source.get('titre')} — {source.get('entreprise')}"
        )
        print(f"  {source.get('ville')} | {source.get('contrat')} | {salaire}")
        print(f"  {extrait}")

    aggregations = reponse.get("aggregations", {})
    afficher_facette("Villes", aggregations.get("villes", {}).get("buckets", []))
    afficher_facette("Contrats", aggregations.get("contrats", {}).get("buckets", []))
    afficher_facette(
        "Compétences",
        aggregations.get("competences", {}).get("buckets", []),
    )


if __name__ == "__main__":
    main()
