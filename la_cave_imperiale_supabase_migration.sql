-- LA CAVE IMPÉRIALE — Migration de raccordement de l'index.html à Supabase
-- À exécuter APRÈS le schéma principal dans Supabase > SQL Editor.

-- Empêche l'auto-promotion d'un utilisateur vers admin.
DROP POLICY IF EXISTS profiles_update ON public.profiles;
CREATE POLICY profiles_update
ON public.profiles FOR UPDATE TO authenticated
USING (public.current_role() = 'admin')
WITH CHECK (public.current_role() = 'admin');

-- Espace de travail partagé : conserve la structure S de l'application HTML actuelle.
-- Les modules existants (Articles, Entrées, Sorties, Commandes, Caisse, Staff,
-- RH&RM, Clôtures, etc.) sont synchronisés ensemble dans data (JSONB).
CREATE TABLE IF NOT EXISTS public.cave_app_state (
  id integer PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  data jsonb NOT NULL DEFAULT '{}'::jsonb,
  updated_by uuid REFERENCES public.profiles(id),
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.cave_app_state ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE ON public.cave_app_state TO authenticated;
DROP POLICY IF EXISTS cave_app_state_read ON public.cave_app_state;
CREATE POLICY cave_app_state_read ON public.cave_app_state
FOR SELECT TO authenticated USING (public.is_staff());
DROP POLICY IF EXISTS cave_app_state_insert ON public.cave_app_state;
CREATE POLICY cave_app_state_insert ON public.cave_app_state
FOR INSERT TO authenticated WITH CHECK (public.current_role() = 'admin' AND updated_by = auth.uid());
DROP POLICY IF EXISTS cave_app_state_update ON public.cave_app_state;
CREATE POLICY cave_app_state_update ON public.cave_app_state
FOR UPDATE TO authenticated USING (public.is_staff())
WITH CHECK (public.is_staff() AND updated_by = auth.uid());

-- Les vues de reporting doivent respecter les droits de l'utilisateur appelant.
ALTER VIEW public.v_stock_actuel SET (security_invoker = true);
ALTER VIEW public.v_dashboard_global SET (security_invoker = true);
ALTER VIEW public.v_dashboard_categories SET (security_invoker = true);
ALTER VIEW public.v_dashboard_journalier SET (security_invoker = true);
ALTER VIEW public.v_stock_alertes SET (security_invoker = true);
ALTER VIEW public.v_dettes_clients SET (security_invoker = true);

-- À exécuter après création du compte Auth efxscreenm@gmail.com :
-- UPDATE public.profiles SET role='admin', actif=true
-- WHERE lower(email)=lower('efxscreenm@gmail.com');
