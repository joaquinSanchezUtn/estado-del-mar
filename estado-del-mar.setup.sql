-- ============================================================
-- ESTADO DEL MAR — Setup de base de datos (Supabase)
-- Pegar y ejecutar completo en: Proyecto > SQL Editor > New query
-- ============================================================

-- 1) Perfil de cada suscriptor (además de lo que ya guarda Supabase Auth)
create table if not exists public.profiles (
  id uuid references auth.users on delete cascade primary key,
  email text,
  subscribed boolean default false,
  subscribed_at timestamp with time zone,
  is_admin boolean default false,
  created_at timestamp with time zone default now()
);

-- 2) Crear el perfil automáticamente apenas alguien se registra
create or replace function public.handle_new_user()
returns trigger as $$
begin
  insert into public.profiles (id, email, full_name)
  values (new.id, new.email, new.raw_user_meta_data->>'name')
  on conflict (id) do nothing;
  return new;
end;
$$ language plpgsql security definer;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- 3) Las ventanas / temas (lo que hoy edita el panel de administración)
create table if not exists public.topics (
  id text primary key,
  title text not null,
  emoji text,
  gradient text,
  description text,
  questions jsonb,
  levels jsonb,
  slides jsonb,
  meditation jsonb,
  exercise jsonb,
  created_at timestamp with time zone default now()
);

-- 4) Seguridad: activar Row Level Security en ambas tablas
alter table public.profiles enable row level security;
alter table public.topics enable row level security;

-- 5) Políticas de perfiles: cada quien ve y edita solo el suyo
drop policy if exists "ver_mi_perfil" on public.profiles;
create policy "ver_mi_perfil"
  on public.profiles for select
  using (auth.uid() = id);

drop policy if exists "editar_mi_perfil" on public.profiles;
create policy "editar_mi_perfil"
  on public.profiles for update
  using (auth.uid() = id);

-- 6) Políticas de ventanas: lectura pública (el menú lo ve todo el mundo),
--    escritura solo para quien tenga is_admin = true en su perfil
drop policy if exists "cualquiera_puede_leer_ventanas" on public.topics;
create policy "cualquiera_puede_leer_ventanas"
  on public.topics for select
  using (true);

drop policy if exists "solo_admin_crea_ventanas" on public.topics;
create policy "solo_admin_crea_ventanas"
  on public.topics for insert
  with check (exists (select 1 from public.profiles where id = auth.uid() and is_admin = true));

drop policy if exists "solo_admin_edita_ventanas" on public.topics;
create policy "solo_admin_edita_ventanas"
  on public.topics for update
  using (exists (select 1 from public.profiles where id = auth.uid() and is_admin = true));

drop policy if exists "solo_admin_borra_ventanas" on public.topics;
create policy "solo_admin_borra_ventanas"
  on public.topics for delete
  using (exists (select 1 from public.profiles where id = auth.uid() and is_admin = true));

-- 7) Datos personales del perfil (panel "Mi perfil")
alter table public.profiles add column if not exists full_name text;
alter table public.profiles add column if not exists phone text;
alter table public.profiles add column if not exists country text;
alter table public.profiles add column if not exists city text;
alter table public.profiles add column if not exists birth_date date;
alter table public.profiles add column if not exists motivation text;

-- ============================================================
-- PASO MANUAL (hacer DESPUÉS de registrarte una vez en el sitio):
-- reemplazá el email por el que usaste para registrarte, y ejecutá
-- esta línea sola para convertirte en administrador/a del panel:
--
-- update public.profiles set is_admin = true where email = 'tu@email.com';
-- ============================================================
