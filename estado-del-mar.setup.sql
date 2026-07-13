-- ============================================================
-- ESTADO DEL MAR — Setup de base de datos (Supabase)
-- Pegar y ejecutar completo en: Proyecto > SQL Editor > New query
-- Es idempotente: se puede re-correr entero sin errores.
-- ============================================================

-- 1) Perfil de cada suscriptor (además de lo que ya guarda Supabase Auth)
-- S4: full_name y el resto de datos personales ya están en CREATE TABLE para que
--     el trigger handle_new_user nunca referencie una columna inexistente si el
--     script se corre por partes. Las secciones posteriores repiten ADD COLUMN IF NOT EXISTS
--     (idempotente) por compatibilidad con bases ya existentes.
create table if not exists public.profiles (
  id uuid references auth.users on delete cascade primary key,
  email text,
  subscribed boolean default false,
  subscribed_at timestamp with time zone,
  is_admin boolean default false,
  created_at timestamp with time zone default now(),
  full_name text,
  phone text,
  country text,
  city text,
  birth_date date,
  motivation text
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

-- 3) Las ventanas / temas (lo que edita el panel de administración)
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

-- S1: el usuario puede editar su propio perfil, pero NO puede cambiar is_admin.
-- El WITH CHECK compara el nuevo valor de is_admin contra el que ya tiene en la base,
-- para que nunca pueda escribir is_admin=true desde la consola de Supabase.
-- NOTA: subscribed se deja modificable a propósito (la suscripción es demo sin pago real).
-- Cuando se integren pagos reales, habrá que agregar un check similar para subscribed
-- y manejar esa columna solo desde funciones server-side con security definer.
drop policy if exists "editar_mi_perfil" on public.profiles;
create policy "editar_mi_perfil"
  on public.profiles for update
  using (auth.uid() = id)
  with check (
    auth.uid() = id
    and is_admin = (select p.is_admin from public.profiles p where p.id = auth.uid())
  );

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

-- 8) Media y orden de las ventanas (para el panel de administración ampliado)
alter table public.topics add column if not exists video_url text;
alter table public.topics add column if not exists audio_url text;
alter table public.topics add column if not exists sort_order integer default 0;

-- Portada opcional de cada ventana (imagen comprimida en el navegador antes de subir).
alter table public.topics add column if not exists cover_url text;

-- 9) Almacenamiento de archivos (videos y audios que suben los administradores)
--    Bucket público "media": cualquiera puede VER los archivos (para reproducir),
--    pero solo un administrador puede SUBIR / cambiar / borrar.
insert into storage.buckets (id, name, public)
values ('media', 'media', true)
on conflict (id) do nothing;

drop policy if exists "media_lectura_publica" on storage.objects;
create policy "media_lectura_publica"
  on storage.objects for select
  using (bucket_id = 'media');

drop policy if exists "media_admin_sube" on storage.objects;
create policy "media_admin_sube"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'media' and exists (select 1 from public.profiles where id = auth.uid() and is_admin = true));

drop policy if exists "media_admin_edita" on storage.objects;
create policy "media_admin_edita"
  on storage.objects for update to authenticated
  using (bucket_id = 'media' and exists (select 1 from public.profiles where id = auth.uid() and is_admin = true));

drop policy if exists "media_admin_borra" on storage.objects;
create policy "media_admin_borra"
  on storage.objects for delete to authenticated
  using (bucket_id = 'media' and exists (select 1 from public.profiles where id = auth.uid() and is_admin = true));

-- 10) Configuración general de la app (precio de la suscripción, etc.)
--     Una sola fila (id = 'main'). Cualquiera puede leer el precio;
--     solo un administrador puede cambiarlo desde el panel.
create table if not exists public.app_config (
  id    text primary key default 'main',
  price text not null default '9.990'
);

insert into public.app_config (id, price)
values ('main', '9.990')
on conflict (id) do nothing;

alter table public.app_config enable row level security;

drop policy if exists "config_lectura_publica" on public.app_config;
create policy "config_lectura_publica"
  on public.app_config for select
  using (true);

drop policy if exists "config_solo_admin_edita" on public.app_config;
create policy "config_solo_admin_edita"
  on public.app_config for update
  using (exists (select 1 from public.profiles where id = auth.uid() and is_admin = true));

drop policy if exists "config_solo_admin_inserta" on public.app_config;
create policy "config_solo_admin_inserta"
  on public.app_config for insert
  with check (exists (select 1 from public.profiles where id = auth.uid() and is_admin = true));

-- 11) Permitir que cada usuario cree/actualice su propio perfil (para el upsert de suscripción/datos)
drop policy if exists "insertar_mi_perfil" on public.profiles;
create policy "insertar_mi_perfil"
  on public.profiles for insert
  with check (auth.uid() = id);

-- 12) Configuración de WhatsApp editable desde el panel de administración (B10)
alter table public.app_config add column if not exists whatsapp text;
alter table public.app_config add column if not exists whatsapp_msg text;

-- 13) Modelo de suscripción mensual con acceso hasta vencimiento
--     subscription_until: hasta qué fecha y hora tiene acceso el usuario (null = sin vencimiento, acceso permanente para suscriptores legacy).
--     auto_renew: si la suscripción se renueva automáticamente al vencer. Cuando se integren pagos reales, la pasarela de pago maneja este flag.
--     null en auto_renew se trata como true (suscriptores previos al cambio siguen activos con normalidad).
alter table public.profiles add column if not exists subscription_until timestamp with time zone;
alter table public.profiles add column if not exists auto_renew boolean default false;

-- ============================================================
-- PASO MANUAL (hacer DESPUÉS de registrarte una vez en el sitio):
-- reemplazá el email por el que usaste para registrarte, y ejecutá
-- esta línea sola para convertirte en administrador/a del panel:
--
-- update public.profiles set is_admin = true where email = 'tu@email.com';
-- ============================================================
