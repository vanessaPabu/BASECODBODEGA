-- =====================================================================
--  BODEGA ATLANTIC · Script 8: recibir por partes
--  Cada producto recibido guarda su tipo (NORMAL o PESO) y las partes que se bajaron
--  (cada parte es una estiba y tiene su propio rótulo).
--  Pégalo en Supabase → SQL Editor → Run. Se puede correr más de una vez.
-- =====================================================================
alter table public.recepcion_items add column if not exists tipo text not null default 'NORMAL';
alter table public.recepcion_items add column if not exists partes jsonb not null default '[]';

select 'Listo: recibir por partes' as resultado;
