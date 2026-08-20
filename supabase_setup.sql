-- Enterprise Podcast Studio — setup Supabase
-- Rodar no SQL Editor do projeto pxcqyzbgfbwwkazmonzx (mesmo projeto do
-- BIG GTD / Finanças Casa / Agenda Renata / CBS)
-- Tabelas prefixadas "eps_" pra ficar isolado dos outros apps no mesmo projeto.
--
-- Este arquivo é IDEMPOTENTE (pode rodar de novo sem quebrar nada).

-- ============================================================
-- 1. USUÁRIOS AUTORIZADOS (allowlist + perfil de cada um)
-- ============================================================
create table if not exists eps_usuarios (
  email text primary key,
  nome text not null,
  apelido text unique,
  posicao text not null check (posicao in ('Administrador','Operador')),
  created_at timestamptz default now()
);

-- resolve apelido -> e-mail pra login curto. security definer + grant pro anon porque
-- isso roda ANTES de autenticar (não dá pra depender de RLS de eps_usuarios, que exige
-- estar logado). Só devolve o e-mail — não dá pra enumerar usuários por aqui.
create or replace function eps_email_by_apelido(p_apelido text)
returns text language sql security definer stable as $$
  select email from eps_usuarios where apelido = lower(p_apelido) limit 1;
$$;
grant execute on function eps_email_by_apelido(text) to anon, authenticated;

create or replace function eps_is_authorized()
returns boolean language sql security definer stable as $$
  select exists (select 1 from eps_usuarios where email = auth.jwt() ->> 'email');
$$;
create or replace function eps_is_admin()
returns boolean language sql security definer stable as $$
  select exists (select 1 from eps_usuarios where email = auth.jwt() ->> 'email' and posicao = 'Administrador');
$$;

alter table eps_usuarios enable row level security;
drop policy if exists "eps_usuarios - leitura autorizados" on eps_usuarios;
create policy "eps_usuarios - leitura autorizados" on eps_usuarios
  for select using (eps_is_authorized());
drop policy if exists "eps_usuarios - admin insere" on eps_usuarios;
create policy "eps_usuarios - admin insere" on eps_usuarios
  for insert with check (eps_is_admin());
drop policy if exists "eps_usuarios - admin atualiza" on eps_usuarios;
create policy "eps_usuarios - admin atualiza" on eps_usuarios
  for update using (eps_is_admin()) with check (eps_is_admin());
drop policy if exists "eps_usuarios - admin remove" on eps_usuarios;
create policy "eps_usuarios - admin remove" on eps_usuarios
  for delete using (eps_is_admin());

-- ============================================================
-- 2. COMISSIONADOS (dado financeiro — só Administrador)
-- ============================================================
create table if not exists eps_comissionados (
  id bigint generated always as identity primary key,
  nome text not null,
  whatsapp text,
  pix text,
  pct numeric(6,2) default 0,
  ativo boolean default true,
  created_at timestamptz default now()
);
alter table eps_comissionados enable row level security;
drop policy if exists "eps_comissionados - admin" on eps_comissionados;
create policy "eps_comissionados - admin" on eps_comissionados
  for all using (eps_is_admin()) with check (eps_is_admin());

-- ============================================================
-- 3. CLIENTES (Administrador e Operador podem ler/escrever)
-- ============================================================
create table if not exists eps_clientes (
  id bigint generated always as identity primary key,
  nome text not null,
  whatsapp text,
  empresa text,
  email text,
  endereco text,
  documento text,
  instagram text,
  aniversario date,
  comissionado_id bigint references eps_comissionados(id) on delete set null,
  created_at timestamptz default now()
);
alter table eps_clientes enable row level security;
drop policy if exists "eps_clientes - autorizados" on eps_clientes;
create policy "eps_clientes - autorizados" on eps_clientes
  for all using (eps_is_authorized()) with check (eps_is_authorized());

-- ============================================================
-- 4. RESERVAS / AGENDA (Administrador e Operador podem ler/escrever)
-- ============================================================
create table if not exists eps_reservas (
  id bigint generated always as identity primary key,
  cliente_id bigint references eps_clientes(id) on delete set null,
  podcast text,
  data date not null,
  hora text not null,
  duracao int default 90,
  valor_base numeric(10,2) default 0,
  extras jsonb default '[]',
  valor numeric(10,2) default 0,
  pagamento text default 'pendente' check (pagamento in ('pendente','pago')),
  forma_pagamento text,
  contrato_link text,
  status text default 'Agendado',
  obs text,
  created_at timestamptz default now()
);
alter table eps_reservas enable row level security;
drop policy if exists "eps_reservas - autorizados" on eps_reservas;
create policy "eps_reservas - autorizados" on eps_reservas
  for all using (eps_is_authorized()) with check (eps_is_authorized());

-- ============================================================
-- 5. DESPESAS / CONTAS A PAGAR (dado financeiro — só Administrador)
-- ============================================================
create table if not exists eps_despesas (
  id bigint generated always as identity primary key,
  descricao text not null,
  valor numeric(10,2) default 0,
  data date not null,
  categoria text default 'Outros',
  recorrente boolean default false,
  pago boolean default false,
  comissionado_id bigint references eps_comissionados(id) on delete set null,
  created_at timestamptz default now()
);
alter table eps_despesas enable row level security;
drop policy if exists "eps_despesas - admin" on eps_despesas;
create policy "eps_despesas - admin" on eps_despesas
  for all using (eps_is_admin()) with check (eps_is_admin());

-- ============================================================
-- 6. HORÁRIOS DA AGENDA (todo autorizado lê, só Administrador edita)
-- ============================================================
create table if not exists eps_horarios (
  dia text primary key check (dia in ('dom','seg','ter','qua','qui','sex','sab')),
  horarios jsonb not null default '[]'
);
alter table eps_horarios enable row level security;
drop policy if exists "eps_horarios - leitura autorizados" on eps_horarios;
create policy "eps_horarios - leitura autorizados" on eps_horarios
  for select using (eps_is_authorized());
drop policy if exists "eps_horarios - admin edita" on eps_horarios;
create policy "eps_horarios - admin edita" on eps_horarios
  for insert with check (eps_is_admin());
drop policy if exists "eps_horarios - admin atualiza" on eps_horarios;
create policy "eps_horarios - admin atualiza" on eps_horarios
  for update using (eps_is_admin()) with check (eps_is_admin());

-- seed dos horários padrão (mesma lógica de hoje: seg-qui só à noite por causa
-- do IA Hub usar a sala de dia, sexta o dia inteiro, fim de semana livre)
insert into eps_horarios (dia, horarios) values
  ('dom', '[]'),
  ('seg', '["19:00","20:30"]'),
  ('ter', '["19:00","20:30"]'),
  ('qua', '["19:00","20:30"]'),
  ('qui', '["19:00","20:30"]'),
  ('sex', '["08:00","09:30","11:00","12:30","14:00","16:00","17:30","19:00","20:30"]'),
  ('sab', '["09:00","11:00","14:00","16:00","18:00","20:00"]')
on conflict (dia) do nothing;

-- ============================================================
-- 7. CONFIG (meta de faturamento, prazo de repasse — só Administrador)
-- ============================================================
create table if not exists eps_config (
  id boolean primary key default true check (id),
  meta_faturamento numeric(10,2) default 0,
  prazo_repasse_dias int default 5
);
insert into eps_config (id) values (true) on conflict (id) do nothing;
alter table eps_config enable row level security;
drop policy if exists "eps_config - admin" on eps_config;
create policy "eps_config - admin" on eps_config
  for all using (eps_is_admin()) with check (eps_is_admin());

-- ============================================================
-- 8. PRIMEIRO ADMINISTRADOR (bootstrap — sem isso ninguém consegue
--    nem abrir a tela de Usuários pra cadastrar os demais)
-- ============================================================
insert into eps_usuarios (email, nome, apelido, posicao) values
  ('bruno.rivero@gmail.com', 'Bruno Rivero', 'bruno', 'Administrador')
on conflict (email) do update set nome = excluded.nome, apelido = excluded.apelido, posicao = excluded.posicao;
