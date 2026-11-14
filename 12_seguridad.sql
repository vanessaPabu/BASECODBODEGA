-- =====================================================================
--  BODEGA ATLANTIC · Script 12: seguridad
--   - Cada persona entra con su PIN de 4 dígitos (se guarda cifrado, nadie lo puede leer)
--   - Sesión con token: al recargar la página no hay que volver a entrar
--     (la sesión dura 12 horas desde el último uso; "Salir" la cierra)
--   - Usuarios y permisos: solo quien tenga el permiso "usuarios" los puede crear o cambiar
--   - 5 PIN equivocados seguidos bloquean a esa persona 5 minutos
--  Primera vez: entra como Jefe y crea tu PIN. Ese primer usuario queda como administrador.
--  Pégalo en Supabase → SQL Editor → Run. Se puede correr más de una vez.
-- =====================================================================

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

-- Permisos de cada persona (lo que puede hacer en la app)
alter table public.operarios add column if not exists permisos text[] not null default '{}';

-- Datos secretos: PIN cifrado e intentos. Sin políticas = nadie los lee directamente.
create table if not exists public.operario_seguridad (
  operario_id      text primary key references public.operarios(operario_id) on delete cascade,
  pin_hash         text,
  intentos         int not null default 0,
  bloqueado_hasta  timestamptz,
  pin_cambiado     timestamptz
);
alter table public.operario_seguridad enable row level security;

create table if not exists public.sesiones (
  token        uuid primary key default gen_random_uuid(),
  operario_id  text not null references public.operarios(operario_id) on delete cascade,
  sede_id      text,
  creada       timestamptz not null default now(),
  ultima       timestamptz not null default now(),
  expira       timestamptz not null,
  activa       boolean not null default true
);
create index if not exists sesiones_op on public.sesiones (operario_id);
alter table public.sesiones enable row level security;

-- Los operarios solo se pueden LEER desde la app; crear o cambiar va por las funciones de abajo
drop policy if exists app on public.operarios;
drop policy if exists leer on public.operarios;
create policy leer on public.operarios for select to authenticated using (true);

-- Permisos por defecto para lo que ya existía
update public.operarios set permisos = array['ubicar','mover','salida','rotular','recibir','calidad','inv_recibo','reportes','productos','estructura','config','usuarios']
  where rol = 'JEFE' and permisos = '{}';
update public.operarios set permisos = array['ubicar','mover','salida','rotular','recibir']
  where rol = 'OPERARIO' and permisos = '{}';

-- ---------- Ayudas internas ----------
create or replace function public.seg_permisos_validos(p text[]) returns text[]
language sql immutable as $$
  select coalesce(array_agg(distinct x order by x), '{}') from unnest(p) x
  where x = any (array['ubicar','mover','salida','rotular','recibir','calidad','inv_recibo','reportes','productos','estructura','config','usuarios'])
$$;

-- Quién es el dueño de un token (o nada si ya no sirve)
create or replace function public.seg_operario(p_token uuid) returns public.operarios
language plpgsql security definer set search_path = public, extensions as $$
declare o operarios;
begin
  select op.* into o from sesiones s join operarios op on op.operario_id = s.operario_id
   where s.token = p_token and s.activa and s.expira > now() and op.activo;
  return o;
end $$;

create or replace function public.seg_info(o public.operarios, p_token uuid) returns jsonb
language sql stable as $$
  select jsonb_build_object('ok', true, 'token', p_token, 'id', o.operario_id, 'nombre', o.nombre, 'rol', o.rol, 'permisos', to_jsonb(o.permisos))
$$;

-- ---------- Entrar con PIN ----------
-- Devuelve { ok, token, nombre, rol, permisos } o { ok:false, error } (no lanza error para que los intentos queden guardados)
create or replace function public.bd_login(p_nombre text, p_pin text, p_sede text default null, p_confirmar boolean default false)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  o operarios; s operario_seguridad; t uuid; quedan int;
begin
  select * into o from operarios where nombre = p_nombre and activo;
  if o.operario_id is null then return jsonb_build_object('ok', false, 'error', 'Ese usuario no existe o está desactivado'); end if;
  if coalesce(p_pin, '') !~ '^\d{4}$' then return jsonb_build_object('ok', false, 'error', 'El PIN son 4 números'); end if;

  insert into operario_seguridad (operario_id) values (o.operario_id) on conflict do nothing;
  select * into s from operario_seguridad where operario_id = o.operario_id for update;

  if s.bloqueado_hasta is not null and s.bloqueado_hasta > now() then
    return jsonb_build_object('ok', false, 'error',
      'Demasiados intentos. Espera ' || greatest(1, ceil(extract(epoch from (s.bloqueado_hasta - now())) / 60))::int || ' minuto(s) o pide al administrador que te cambie el PIN.');
  end if;

  if s.pin_hash is null then
    -- Primera vez de todo el sistema: el primer Jefe crea su PIN y queda como administrador
    if o.rol = 'JEFE' and not exists (select 1 from operario_seguridad where pin_hash is not null) then
      if not p_confirmar then return jsonb_build_object('ok', false, 'primerPin', true); end if;
      update operario_seguridad set pin_hash = crypt(p_pin, gen_salt('bf')), intentos = 0, pin_cambiado = now() where operario_id = o.operario_id;
      update operarios set permisos = seg_permisos_validos(permisos || array['usuarios']) where operario_id = o.operario_id returning * into o;
    else
      return jsonb_build_object('ok', false, 'error', 'Todavía no tienes PIN. Pídele al administrador que te lo asigne.');
    end if;
  elsif s.pin_hash <> crypt(p_pin, s.pin_hash) then
    update operario_seguridad set intentos = intentos + 1,
      bloqueado_hasta = case when intentos + 1 >= 5 then now() + interval '5 minutes' else null end
      where operario_id = o.operario_id returning 5 - intentos into quedan;
    if quedan <= 0 then
      update operario_seguridad set intentos = 0 where operario_id = o.operario_id;
      return jsonb_build_object('ok', false, 'error', 'PIN incorrecto. Quedaste bloqueado 5 minutos.');
    end if;
    return jsonb_build_object('ok', false, 'error', 'PIN incorrecto. Te quedan ' || quedan || ' intento' || case when quedan = 1 then '' else 's' end || '.');
  end if;

  update operario_seguridad set intentos = 0, bloqueado_hasta = null where operario_id = o.operario_id;
  insert into sesiones (operario_id, sede_id, expira) values (o.operario_id, p_sede, now() + interval '12 hours') returning token into t;
  return seg_info(o, t);
end $$;

-- ---------- Seguir con la sesión guardada (al recargar) ----------
create or replace function public.bd_sesion(p_token uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare o operarios;
begin
  o := seg_operario(p_token);
  if o.operario_id is null then return jsonb_build_object('ok', false); end if;
  update sesiones set ultima = now(), expira = now() + interval '12 hours' where token = p_token;
  return seg_info(o, p_token);
end $$;

create or replace function public.bd_salir(p_token uuid) returns void
language sql security definer set search_path = public as $$
  update sesiones set activa = false where token = p_token;
$$;

-- ---------- Administración de usuarios (permiso "usuarios") ----------
create or replace function public.seg_admin(p_token uuid) returns public.operarios
language plpgsql security definer set search_path = public, extensions as $$
declare o operarios;
begin
  o := seg_operario(p_token);
  if o.operario_id is null then raise exception 'Tu sesión terminó. Vuelve a entrar.'; end if;
  if not ('usuarios' = any (o.permisos)) then raise exception 'No tienes permiso para administrar usuarios'; end if;
  return o;
end $$;

create or replace function public.bd_usuarios(p_token uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform seg_admin(p_token);
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', o.operario_id, 'nombre', o.nombre, 'rol', o.rol, 'activo', o.activo, 'permisos', to_jsonb(o.permisos),
      'tienePin', s.pin_hash is not null, 'bloqueado', coalesce(s.bloqueado_hasta > now(), false),
      'ultimaVez', (select max(ultima) from sesiones x where x.operario_id = o.operario_id))
      order by o.activo desc, o.nombre)
    from operarios o left join operario_seguridad s on s.operario_id = o.operario_id), '[]'::jsonb);
end $$;

-- d: { id (vacío = nuevo), nombre, rol, activo, permisos[], pin (opcional: solo si se cambia) }
create or replace function public.bd_guardar_usuario(p_token uuid, d jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  yo operarios; o operarios;
  v_id text := nullif(trim(coalesce(d->>'id', '')), '');
  v_nombre text := trim(coalesce(d->>'nombre', ''));
  v_rol text := upper(coalesce(d->>'rol', 'OPERARIO'));
  v_activo boolean := coalesce((d->>'activo')::boolean, true);
  v_pin text := nullif(trim(coalesce(d->>'pin', '')), '');
  v_perm text[] := seg_permisos_validos(coalesce(array(select jsonb_array_elements_text(d->'permisos')), '{}'));
begin
  yo := seg_admin(p_token);
  if v_nombre = '' then raise exception 'Escribe el nombre'; end if;
  if v_rol not in ('OPERARIO', 'JEFE') then raise exception 'Rol no válido'; end if;
  if v_pin is not null and v_pin !~ '^\d{4}$' then raise exception 'El PIN deben ser 4 números'; end if;
  if v_id is null and v_pin is null then raise exception 'Asígnale un PIN de 4 números'; end if;
  if exists (select 1 from operarios where upper(nombre) = upper(v_nombre) and operario_id is distinct from v_id) then
    raise exception 'Ya existe un usuario llamado %', v_nombre;
  end if;
  -- No se puede quitar uno mismo el acceso a esta pantalla
  if v_id = yo.operario_id and (not v_activo or not ('usuarios' = any (v_perm))) then
    raise exception 'No te puedes quitar a ti mismo el permiso de usuarios ni desactivarte';
  end if;

  if v_id is null then
    v_id := 'OP' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
    insert into operarios (operario_id, nombre, rol, activo, permisos) values (v_id, v_nombre, v_rol, v_activo, v_perm);
  else
    update operarios set nombre = v_nombre, rol = v_rol, activo = v_activo, permisos = v_perm where operario_id = v_id returning * into o;
    if o.operario_id is null then raise exception 'No se encontró ese usuario'; end if;
  end if;

  insert into operario_seguridad (operario_id) values (v_id) on conflict do nothing;
  if v_pin is not null then
    update operario_seguridad set pin_hash = crypt(v_pin, gen_salt('bf')), intentos = 0, bloqueado_hasta = null, pin_cambiado = now()
      where operario_id = v_id;
    -- Con PIN nuevo, se cierran sus sesiones abiertas (menos la mía)
    update sesiones set activa = false where operario_id = v_id and token <> p_token;
  end if;
  if not v_activo then update sesiones set activa = false where operario_id = v_id; end if;

  if not exists (select 1 from operarios where activo and 'usuarios' = any (permisos)) then
    raise exception 'Debe quedar al menos un usuario activo con permiso de usuarios';
  end if;
  return bd_usuarios(p_token);
end $$;

-- Quién puede llamar qué
revoke all on function public.seg_operario(uuid), public.seg_admin(uuid), public.seg_info(public.operarios, uuid) from public, anon, authenticated;
revoke all on function public.bd_login(text, text, text, boolean), public.bd_sesion(uuid), public.bd_salir(uuid),
  public.bd_usuarios(uuid), public.bd_guardar_usuario(uuid, jsonb) from public, anon;
grant execute on function public.bd_login(text, text, text, boolean), public.bd_sesion(uuid), public.bd_salir(uuid),
  public.bd_usuarios(uuid), public.bd_guardar_usuario(uuid, jsonb) to authenticated;

select 'Listo: PIN, sesiones y permisos' as resultado;
