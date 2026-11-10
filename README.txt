# La Cave Impériale — raccordement Supabase

## Contenu
- `la_cave_imperiale_supabase.html` : version modifiée de votre `index.html`, avec Supabase Auth, sauvegarde cloud de l'état complet des modules existants et chatbot flottant Gemini/Google Search.
- `la_cave_imperiale_supabase_migration.sql` : migration à exécuter après le schéma SQL principal.
- `supabase/functions/cave-chat/index.ts` : Edge Function du chatbot.
- `supabase/config.toml` : JWT obligatoire pour la fonction.

## Installation
1. Dans Supabase SQL Editor, exécuter d'abord le schéma principal `la_cave_imperiale_schema_supabase.sql` déjà fourni.
2. Exécuter ensuite `la_cave_imperiale_supabase_migration.sql`.
3. Dans Authentication > Users, créer ou confirmer le compte `efxscreenm@gmail.com`.
4. Exécuter ensuite dans SQL Editor :

```sql
UPDATE public.profiles SET role='admin', actif=true
WHERE lower(email)=lower('efxscreenm@gmail.com');
```

5. Déployer la fonction depuis le dossier du projet :

```bash
supabase secrets set GEMINI_API_KEY=VOTRE_CLE_GEMINI
supabase functions deploy cave-chat
```

6. Publier `la_cave_imperiale_supabase.html` sous le nom `index.html` à la place de l'ancienne version.
7. Ouvrir cette version dans le navigateur qui contient les anciennes données `cave_v2` et se connecter comme administrateur. Si la table cloud est vide, le premier administrateur initialise le cloud avec les données locales de ce navigateur. Les autres utilisateurs récupèrent ensuite l'espace de travail partagé.

## Important — modèle de synchronisation
Pour raccorder le plus sûrement possible tous les modules de l'interface actuelle sans réécrire ses calculs, cette version synchronise l'objet complet `S` dans `cave_app_state.data` (JSONB). Les écrans et calculs existants restent inchangés. Le schéma relationnel détaillé (`products`, `sales`, `stock_movements`, etc.) reste disponible mais n'est pas encore alimenté automatiquement par cette couche de compatibilité. Une migration métier vers les tables normalisées devra être une étape distincte avant de supprimer ce stockage JSONB.

L'espace JSONB est partagé entre les membres actifs. Éviter les modifications simultanées du même tableau par plusieurs utilisateurs : cette version synchronise l'état complet et applique la dernière sauvegarde reçue. Les données locales d'origine ne sont pas effacées ; le navigateur conserve un cache `cave_v2`.

La clé publishable Supabase peut être dans le navigateur. La clé Gemini reste uniquement dans les secrets Edge Function. Ne jamais placer `service_role` ou `GEMINI_API_KEY` dans le HTML.
