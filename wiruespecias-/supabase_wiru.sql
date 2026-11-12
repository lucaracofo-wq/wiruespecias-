-- =====================================================================
-- WIRÚ · ESPECIAS ORGÁNICAS — Base de datos de la landing page
-- Ejecutar completo en Supabase → SQL Editor del proyecto de Wirú.
-- Se puede volver a ejecutar sin perder datos.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. PRODUCTOS · el catálogo que muestra la página
--    Para cambiar precios, agregar u ocultar productos: Table Editor → productos
--    · id: identificador corto sin espacios (ej. pimienta-negra)
--    · color: tono de la especia que se ve en el frasco (#RRGGBB)
--    · orden: posición en el catálogo (menor = primero)
--    · activo: false para ocultarlo sin borrarlo
-- ---------------------------------------------------------------------
create table if not exists public.productos (
  id             text primary key check (id ~ '^[a-z0-9-]{2,60}$'),
  nombre         text not null check (char_length(nombre) between 2 and 80),
  categoria      text not null check (char_length(categoria) between 2 and 40),
  color          text not null default '#8A5A2B' check (color ~ '^#[0-9A-Fa-f]{6}$'),
  precio_110     integer not null check (precio_110 > 0),
  precio_260     integer not null check (precio_260 > 0),
  precio_530     integer not null check (precio_530 > 0),
  orden          integer not null default 100,
  activo         boolean not null default true,
  creado_en      timestamptz not null default now(),
  actualizado_en timestamptz not null default now()
);

create or replace function public.tocar_actualizado_en()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.actualizado_en := now();
  return new;
end;
$$;

drop trigger if exists productos_actualizado_en on public.productos;
create trigger productos_actualizado_en
  before update on public.productos
  for each row execute function public.tocar_actualizado_en();

-- ---------------------------------------------------------------------
-- 2. PEDIDOS · se crean desde el carrito ("Enviar pedido")
-- ---------------------------------------------------------------------
create table if not exists public.pedidos (
  id           uuid primary key default gen_random_uuid(),
  numero       bigint generated always as identity unique,
  referencia   text unique,
  creado_en    timestamptz not null default now(),
  estado       text not null default 'nuevo'
               check (estado in ('nuevo','confirmado','despachado','entregado','cancelado')),
  nombre       text not null,
  telefono     text not null,
  ciudad       text not null,
  direccion    text,
  correo       text,
  notas        text,
  acepta_datos boolean not null check (acepta_datos),
  total        bigint not null default 0
);

create table if not exists public.pedido_items (
  id              bigint generated always as identity primary key,
  pedido_id       uuid not null references public.pedidos(id) on delete cascade,
  producto_id     text not null references public.productos(id),
  producto_nombre text not null,
  formato         text not null check (formato in ('110','260','530')),
  cantidad        integer not null check (cantidad between 1 and 999),
  precio_unitario integer not null,
  subtotal        bigint not null
);
create index if not exists pedido_items_pedido_idx   on public.pedido_items(pedido_id);
create index if not exists pedido_items_producto_idx on public.pedido_items(producto_id);

-- ---------------------------------------------------------------------
-- 3. MENSAJES DE CONTACTO · formulario "¿Tienes dudas o buscas una cotización?"
-- ---------------------------------------------------------------------
create table if not exists public.mensajes_contacto (
  id           bigint generated always as identity primary key,
  creado_en    timestamptz not null default now(),
  nombre       text not null check (char_length(nombre) between 2 and 120),
  apellidos    text check (char_length(apellidos) <= 120),
  telefono     text not null check (char_length(telefono) between 7 and 30),
  ciudad       text not null check (char_length(ciudad) between 2 and 80),
  correo       text check (char_length(correo) <= 160),
  mensaje      text not null check (char_length(mensaje) between 3 and 3000),
  acepta_datos boolean not null check (acepta_datos),
  atendido     boolean not null default false
);

-- ---------------------------------------------------------------------
-- 4. SEGURIDAD (RLS) · lo que puede hacer un visitante con la clave publicable
--    · productos: solo leer los activos
--    · mensajes_contacto: solo enviar (no puede leer los de otros)
--    · pedidos y pedido_items: nada directo; solo a través de crear_pedido()
-- ---------------------------------------------------------------------
alter table public.productos         enable row level security;
alter table public.pedidos           enable row level security;
alter table public.pedido_items      enable row level security;
alter table public.mensajes_contacto enable row level security;

revoke all on public.productos, public.pedidos, public.pedido_items, public.mensajes_contacto
  from anon, authenticated;

grant select on public.productos to anon, authenticated;
drop policy if exists "Catalogo publico: productos activos" on public.productos;
create policy "Catalogo publico: productos activos"
  on public.productos for select
  to anon, authenticated
  using (activo);

grant insert (nombre, apellidos, telefono, ciudad, correo, mensaje, acepta_datos)
  on public.mensajes_contacto to anon, authenticated;
drop policy if exists "Visitantes pueden enviar mensajes" on public.mensajes_contacto;
create policy "Visitantes pueden enviar mensajes"
  on public.mensajes_contacto for insert
  to anon, authenticated
  with check (acepta_datos);

-- ---------------------------------------------------------------------
-- 5. FUNCIÓN crear_pedido · registra el pedido con los precios de la base
--    (el navegador no puede alterar precios ni totales)
-- ---------------------------------------------------------------------
create or replace function public.crear_pedido(p_cliente jsonb, p_items jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id      uuid;
  v_numero  bigint;
  v_ref     text;
  v_total   bigint := 0;
  v_item    jsonb;
  v_prod    public.productos%rowtype;
  v_formato text;
  v_cant    integer;
  v_precio  integer;
  v_nombre  text := btrim(coalesce(p_cliente->>'nombre', ''));
  v_tel     text := btrim(coalesce(p_cliente->>'telefono', ''));
  v_ciudad  text := btrim(coalesce(p_cliente->>'ciudad', ''));
  v_dir     text := nullif(btrim(coalesce(p_cliente->>'direccion', '')), '');
  v_correo  text := nullif(btrim(coalesce(p_cliente->>'correo', '')), '');
  v_notas   text := nullif(btrim(coalesce(p_cliente->>'notas', '')), '');
begin
  if char_length(v_nombre) not between 2 and 120 then
    raise exception 'Escribe tu nombre.';
  end if;
  if char_length(v_tel) not between 7 and 30 then
    raise exception 'Escribe un teléfono válido.';
  end if;
  if char_length(v_ciudad) not between 2 and 80 then
    raise exception 'Escribe tu ciudad.';
  end if;
  if char_length(coalesce(v_dir, '')) > 200
     or char_length(coalesce(v_correo, '')) > 160
     or char_length(coalesce(v_notas, '')) > 1000 then
    raise exception 'Alguno de los datos es demasiado largo.';
  end if;
  if coalesce(p_cliente->>'acepta_datos', '') <> 'true' then
    raise exception 'Debes aceptar la Política de Tratamiento de Datos.';
  end if;
  if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'El carrito está vacío.';
  end if;
  if jsonb_array_length(p_items) > 60 then
    raise exception 'Demasiadas líneas en un solo pedido.';
  end if;

  insert into public.pedidos (nombre, telefono, ciudad, direccion, correo, notas, acepta_datos)
  values (v_nombre, v_tel, v_ciudad, v_dir, v_correo, v_notas, true)
  returning id, numero into v_id, v_numero;

  v_ref := 'WIRU-' || to_char(now() at time zone 'America/Bogota', 'YYYYMMDD')
           || '-' || lpad(v_numero::text, 5, '0');

  for v_item in select value from jsonb_array_elements(p_items) loop
    v_formato := v_item->>'formato';
    if v_formato is null or v_formato not in ('110', '260', '530') then
      raise exception 'Presentación no válida.';
    end if;
    if coalesce(v_item->>'cantidad', '') !~ '^[0-9]{1,3}$' then
      raise exception 'Cantidad no válida.';
    end if;
    v_cant := (v_item->>'cantidad')::integer;
    if v_cant not between 1 and 999 then
      raise exception 'La cantidad debe estar entre 1 y 999.';
    end if;

    select * into v_prod
      from public.productos
     where id = v_item->>'producto_id' and activo;
    if not found then
      raise exception 'Uno de los productos ya no está disponible. Recarga la página.';
    end if;

    v_precio := case v_formato
                  when '110' then v_prod.precio_110
                  when '260' then v_prod.precio_260
                  else v_prod.precio_530
                end;

    insert into public.pedido_items
      (pedido_id, producto_id, producto_nombre, formato, cantidad, precio_unitario, subtotal)
    values
      (v_id, v_prod.id, v_prod.nombre, v_formato, v_cant, v_precio, v_precio::bigint * v_cant);

    v_total := v_total + v_precio::bigint * v_cant;
  end loop;

  update public.pedidos set referencia = v_ref, total = v_total where id = v_id;

  return jsonb_build_object(
    'referencia', v_ref,
    'creado_en',  now(),
    'total',      v_total,
    'items', (
      select jsonb_agg(jsonb_build_object(
               'producto',        producto_nombre,
               'formato',         formato,
               'cantidad',        cantidad,
               'precio_unitario', precio_unitario,
               'subtotal',        subtotal) order by id)
        from public.pedido_items
       where pedido_id = v_id)
  );
end;
$$;

revoke all on function public.crear_pedido(jsonb, jsonb) from public;
grant execute on function public.crear_pedido(jsonb, jsonb) to anon, authenticated;

-- ---------------------------------------------------------------------
-- 6. CATÁLOGO INICIAL (las 10 especias estrella de la página)
--    No sobrescribe productos que ya existan.
-- ---------------------------------------------------------------------
insert into public.productos (id, nombre, categoria, color, precio_110, precio_260, precio_530, orden) values
  ('comino-molido',           'Comino molido',           'Condimentos',   '#8A5A2B', 12000, 24000, 41000,  10),
  ('ajo-molido',              'Ajo molido',              'Condimentos',   '#E3D3AE', 10000, 21000, 34000,  20),
  ('achiote-molido',          'Achiote molido',          'Condimentos',   '#B5401F', 11000, 22000, 38000,  30),
  ('paprika',                 'Paprika',                 'Condimentos',   '#C0392B', 12000, 23000, 39000,  40),
  ('curcuma',                 'Cúrcuma',                 'Especias',      '#D4A843', 11000, 21000, 35000,  50),
  ('sal-rosada-del-himalaya', 'Sal rosada del Himalaya', 'Sales gourmet', '#E9A79F', 11000, 22000, 37000,  60),
  ('oregano-molido',          'Orégano molido',          'Hierbas',       '#6E7C3C', 12000, 23000, 39000,  70),
  ('jengibre-molido',         'Jengibre molido',         'Especias',      '#CBA85C', 12000, 23000, 39000,  80),
  ('semilla-de-chia',         'Semilla de chía',         'Semillas',      '#3B332A', 11000, 22000, 38000,  90),
  ('canela-molida',           'Canela molida',           'Especias',      '#9C5221', 16000, 32000, 58000, 100)
on conflict (id) do nothing;
