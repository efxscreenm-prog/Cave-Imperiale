-- =====================================================================
--  La Cave Impériale — schéma Supabase (à coller dans SQL Editor > Run)
--  Administrateur : efxscreenm@gmail.com (identifié par son e-mail vérifié)
-- =====================================================================
create extension if not exists pgcrypto;

-- ---------- Fonctions de sécurité ----------
create or replace function public.is_admin() returns boolean
language sql stable as $$
  select lower(coalesce(auth.jwt() ->> 'email', '')) = 'efxscreenm@gmail.com'
$$;

-- ---------- Tables ----------
create table if not exists public.profiles (
  id             uuid primary key references auth.users(id) on delete cascade,
  email          text not null,
  nom            text,
  prenoms        text,
  sexe           text check (sexe in ('M','F')),
  date_naissance date,
  lieu_naissance text,
  situation      text,
  plan_demande   text not null default 'M' check (plan_demande in ('M','T','S','A')),
  cree_at        timestamptz not null default now()
);

create table if not exists public.abonnements (
  user_id uuid primary key references auth.users(id) on delete cascade,
  plan    text not null check (plan in ('M','T','S','A')),
  statut  text not null check (statut in ('actif','suspendu')),
  debut   date not null,
  fin     date not null,
  fin_at  timestamptz not null,          -- instant exact de fin (comparé à now())
  maj_at  timestamptz not null default now(),
  par     text
);

create or replace function public.sub_active(p_user uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.abonnements a
                 where a.user_id = p_user and a.statut = 'actif' and a.fin_at > now())
$$;

create table if not exists public.paiements (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  email      text,
  nom        text,
  plan       text not null check (plan in ('M','T','S','A')),
  montant    integer not null,
  operateur  text,
  numero     text,
  reference  text,
  statut     text not null default 'declare' check (statut in ('declare','valide','rejete')),
  cree_at    timestamptz not null default now(),
  traite_at  timestamptz,
  traite_par text
);
create index if not exists paiements_user_idx on public.paiements(user_id);

create table if not exists public.journal (
  id      bigint generated always as identity primary key,
  ts      timestamptz not null default now(),
  acteur  text,
  action  text,
  cible   uuid,
  details text
);

-- Espace de données de chaque abonné : un document JSON par chemin
-- (articles, entrées/sorties par jour, factures, personnel, RH…)
create table if not exists public.espace_docs (
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  path    text not null,
  data    jsonb not null,
  maj_at  timestamptz not null default now(),
  primary key (user_id, path)
);

create table if not exists public.espace_compteurs (
  user_id uuid primary key references auth.users(id) on delete cascade,
  fcnt    integer not null default 0
);

-- ---------- Création automatique de la fiche à l'inscription ----------
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare m jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
begin
  insert into public.profiles (id, email, nom, prenoms, sexe, date_naissance, lieu_naissance, situation, plan_demande)
  values (new.id, lower(new.email), m->>'nom', m->>'prenoms',
          case when m->>'sexe' in ('M','F') then m->>'sexe' end,
          nullif(m->>'date_naissance','')::date, m->>'lieu_naissance', m->>'situation',
          case when m->>'plan_demande' in ('M','T','S','A') then m->>'plan_demande' else 'M' end)
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- Sécurité au niveau des lignes (RLS) ----------
alter table public.profiles         enable row level security;
alter table public.abonnements      enable row level security;
alter table public.paiements        enable row level security;
alter table public.journal          enable row level security;
alter table public.espace_docs      enable row level security;
alter table public.espace_compteurs enable row level security;

drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select using (id = auth.uid() or public.is_admin());
drop policy if exists profiles_update on public.profiles;
create policy profiles_update on public.profiles for update using (id = auth.uid()) with check (id = auth.uid());
drop policy if exists profiles_delete on public.profiles;
create policy profiles_delete on public.profiles for delete using (public.is_admin());

-- Abonnements : lecture seule pour l'abonné ; écriture uniquement via les fonctions admin_*
drop policy if exists abo_select on public.abonnements;
create policy abo_select on public.abonnements for select using (user_id = auth.uid() or public.is_admin());

drop policy if exists pai_select on public.paiements;
create policy pai_select on public.paiements for select using (user_id = auth.uid() or public.is_admin());
drop policy if exists pai_insert on public.paiements;
create policy pai_insert on public.paiements for insert
  with check (user_id = auth.uid() and statut = 'declare');

drop policy if exists jou_select on public.journal;
create policy jou_select on public.journal for select using (public.is_admin());

-- Espace de données : propriétaire seulement, tant que l'abonnement est actif
drop policy if exists esp_all on public.espace_docs;
create policy esp_all on public.espace_docs for all
  using      (user_id = auth.uid() and (public.is_admin() or public.sub_active(auth.uid())))
  with check (user_id = auth.uid() and (public.is_admin() or public.sub_active(auth.uid())));
-- espace_compteurs : aucune politique (accessible uniquement par la fonction ci-dessous)

-- ---------- Numéro de facture sans doublon ----------
create or replace function public.prochain_numero_facture(p_min integer default 0) returns integer
language plpgsql security definer set search_path = public as $$
declare v_n integer; v_max integer;
begin
  if auth.uid() is null or not (public.is_admin() or public.sub_active(auth.uid())) then
    raise exception 'acces refuse' using errcode = '42501';
  end if;
  insert into espace_compteurs(user_id, fcnt) values (auth.uid(), 0) on conflict do nothing;
  select fcnt into v_n from espace_compteurs where user_id = auth.uid() for update;
  select coalesce(max(substring(path from 'IMP-([0-9]+)')::integer), 0) into v_max
    from espace_docs where user_id = auth.uid() and path like 'factures/%';
  v_n := greatest(v_n, v_max, coalesce(p_min, 0)) + 1;
  update espace_compteurs set fcnt = v_n where user_id = auth.uid();
  return v_n;
end $$;

-- ---------- Actions de l'administrateur ----------
create or replace function public.admin_activer(p_user uuid, p_plan text, p_paiement uuid default null)
returns public.abonnements language plpgsql security definer set search_path = public as $$
declare v_m int; v_base date; v_fin date; v_cur abonnements; v_row abonnements; v_p profiles; v_adm text := lower(auth.jwt() ->> 'email');
begin
  if not public.is_admin() then raise exception 'reserve a l administrateur' using errcode = '42501'; end if;
  v_m := case p_plan when 'M' then 1 when 'T' then 3 when 'S' then 6 when 'A' then 12 end;
  if v_m is null then raise exception 'formule inconnue'; end if;
  select * into v_cur from abonnements where user_id = p_user;
  v_base := case when v_cur.user_id is not null and v_cur.statut = 'actif' and v_cur.fin_at > now()
                 then v_cur.fin + 1 else (now() at time zone 'Africa/Douala')::date end;
  v_fin  := (v_base + make_interval(months => v_m))::date - 1;
  select * into v_p from profiles where id = p_user;
  insert into abonnements (user_id, plan, statut, debut, fin, fin_at, maj_at, par)
  values (p_user, p_plan, 'actif', v_base, v_fin,
          ((v_fin + 1)::timestamp at time zone 'Africa/Douala') - interval '1 second', now(), v_adm)
  on conflict (user_id) do update set plan = excluded.plan, statut = 'actif', debut = excluded.debut,
    fin = excluded.fin, fin_at = excluded.fin_at, maj_at = now(), par = excluded.par
  returning * into v_row;
  if p_paiement is not null then
    update paiements set statut = 'valide', traite_at = now(), traite_par = v_adm where id = p_paiement;
  else
    insert into paiements (user_id, email, nom, plan, montant, operateur, numero, reference, statut, traite_at, traite_par)
    values (p_user, v_p.email, trim(coalesce(v_p.prenoms,'') || ' ' || coalesce(v_p.nom,'')), p_plan,
            case p_plan when 'M' then 1500 when 'T' then 4000 when 'S' then 7500 else 16000 end,
            'Saisie administrateur', '—', '—', 'valide', now(), v_adm);
  end if;
  insert into journal (acteur, action, cible, details) values (v_adm, 'activation', p_user, p_plan || ' jusqu''au ' || v_fin);
  return v_row;
end $$;

create or replace function public.admin_rejeter(p_paiement uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_adm text := lower(auth.jwt() ->> 'email'); v_u uuid;
begin
  if not public.is_admin() then raise exception 'reserve a l administrateur' using errcode = '42501'; end if;
  update paiements set statut = 'rejete', traite_at = now(), traite_par = v_adm
   where id = p_paiement and statut = 'declare' returning user_id into v_u;
  insert into journal (acteur, action, cible, details) values (v_adm, 'rejet', v_u, p_paiement::text);
end $$;

create or replace function public.admin_statut(p_user uuid, p_statut text) returns void
language plpgsql security definer set search_path = public as $$
declare v_adm text := lower(auth.jwt() ->> 'email');
begin
  if not public.is_admin() then raise exception 'reserve a l administrateur' using errcode = '42501'; end if;
  if p_statut not in ('actif','suspendu') then raise exception 'statut invalide'; end if;
  update abonnements set statut = p_statut, maj_at = now(), par = v_adm where user_id = p_user;
  insert into journal (acteur, action, cible, details)
  values (v_adm, case p_statut when 'suspendu' then 'suspension' else 'reactivation' end, p_user, '');
end $$;

revoke all on function public.prochain_numero_facture(integer) from public;
revoke all on function public.admin_activer(uuid, text, uuid)   from public;
revoke all on function public.admin_rejeter(uuid)                from public;
revoke all on function public.admin_statut(uuid, text)           from public;
grant execute on function public.prochain_numero_facture(integer) to authenticated;
grant execute on function public.admin_activer(uuid, text, uuid)   to authenticated;
grant execute on function public.admin_rejeter(uuid)                to authenticated;
grant execute on function public.admin_statut(uuid, text)           to authenticated;

-- ---------- Temps réel ----------
alter table public.espace_docs replica identity full;
do $$ begin
  begin alter publication supabase_realtime add table public.espace_docs;  exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.abonnements;  exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.paiements;    exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.profiles;     exception when duplicate_object then null; end;
end $$;
