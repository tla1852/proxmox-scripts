# proxmox-scripts

## Suivi L5

Ce projet est suivi dans le hub **L5** sous la `ref` **`proxmox-scripts`**.
En fin de tâche significative (feature, fix, jalon), mets L5 à jour via son API agent
(ne pas demander à chaque fois ; en cas d'erreur réseau, continuer sans bloquer) :

- Journaliser : `POST $L5_URL/api/notes` → `{"projet_ref":"proxmox-scripts","titre":"...","contenu":"résumé"}`
- Avancer le projet : `POST $L5_URL/api/projets` → `{"ref":"proxmox-scripts","statut":"en_cours"}`
- Créer une tâche : `POST $L5_URL/api/taches` → `{"projet_ref":"proxmox-scripts","titre":"..."}`
- Logger du temps : `POST $L5_URL/api/temps` → `{"projet_ref":"proxmox-scripts","minutes":N}`

Auth : `Authorization: Bearer $L5_API_TOKEN`. `$L5_URL`/`$L5_API_TOKEN` viennent de l'environnement.
