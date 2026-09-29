# Guía: configurar Supabase + PowerSync para un CLON de este proyecto

> **Para quién:** alguien que clonó este repo y va a levantar SU PROPIA instancia
> (su Supabase nuevo + su PowerSync nuevo). No toca nada de la instancia original.
> **Tiempo estimado:** medio día la primera vez (la mayor parte es el VPS).
> **Fuentes vivas:** `ARQUITECTURA.md §3.8` (arquitectura del sync self-hosted) y
> la memoria de proyecto `powersync-selfhost-hetzner` (runbook original con gotchas).

---

## 0. El mapa — qué habla con qué

```
                 login/JWT · SUBIDA de cobros · fotos · Edge Functions
   ┌────────────┐ ─────────────────────────────────────────────► ┌──────────┐
   │ Dispositivo│                                                │ Supabase │  (fuente
   │  (app)     │ ◄──── BAJADA (sync stream) ──── ┌───────────┐  │ Postgres │   de verdad)
   │ SQLite     │                                 │  TU VPS   │◄─┤ +Auth    │
   │ offline    │                                 │ PowerSync │  replicación
   └────────────┘                                 └───────────┘  (directa, IPv6)
```

- **PowerSync SOLO hace la bajada.** La subida de writes, el login, Storage y las
  Edge Functions van directo a Supabase. Si el VPS cae, la operación sigue
  (offline-first); solo se pausa la propagación entre dispositivos.
- **Los "settings que pasan de Supabase a PowerSync" son exactamente 5** (§2.4):
  host directo de la DB, credenciales del rol de replicación, la CA de Supabase,
  la URL del JWKS de Auth, y la publicación + sync rules.

---

## 1. Supabase nuevo (la fuente de verdad)

1. **Crear el proyecto** en supabase.com (elegir región cercana a los usuarios).
   Anotar del Dashboard → Settings:
   - `PROJECT_REF` (el subdominio: `xxxxx.supabase.co`)
   - **anon key** (Settings → API Keys)
   - **password de la DB** (se define al crear el proyecto)
2. **Vincular el repo y correr TODAS las migraciones** (crean tablas, RLS,
   triggers, funciones, seeds de settings y crons):
   ```
   supabase link --project-ref <PROJECT_REF>
   supabase db push
   ```
   Verificar que no falló ninguna (la salida lista cada archivo aplicado).
3. **Deployar las Edge Functions** (una por una; `_shared/` se bundlea en cada una):
   ```
   supabase functions deploy <nombre> --project-ref <PROJECT_REF> --no-verify-jwt
   ```
   Lista vigente: `crear-tenant`, `invitar-cobrador`, `reenviar-invitacion`,
   `forzar-password-cobrador`, `ver-password-cobrador`, `cambiar-email-cobrador`,
   `eliminar-cobrador`, `whatsapp-set-token`, `whatsapp-enviar`.
   (OJO: `whatsapp-enviar` además necesita el secret `CRON_SECRET` — ver 0239 y
   `supabase secrets set`.)
4. **Crear los buckets de Storage** (Dashboard → Storage, privados):
   `fotos-clientes` · `comprobantes-pago` · `logos-empresa` ·
   `contratos-documentos` · `ticket-adjuntos`.
5. **Auth:** no hay signup público (el onboarding es sin email, password
   server-side por WhatsApp). No habilitar providers extra. Los usuarios los crea
   la Edge `crear-tenant` / `invitar-cobrador`.
6. **Bootstrap:** crear el usuario `super_admin` inicial (fila en `auth.users` +
   `cobradores` con rol `super_admin` — ver `docs/traspaso/MANUAL-DEL-DUENO.md`)
   y desde la app crear el primer tenant con `/super/tenants`.

---

## 2. Preparar la REPLICACIÓN (el lado Supabase del enlace)

Todo esto se corre en el SQL Editor del proyecto nuevo (o `supabase db query --linked`).

### 2.1 Rol dedicado de replicación

```sql
create role powersync_selfhost with login replication password '<PASSWORD_LARGA_RANDOM>';
grant usage on schema public to powersync_selfhost;
grant select on all tables in schema public to powersync_selfhost;
alter default privileges in schema public grant select on tables to powersync_selfhost;
alter role powersync_selfhost bypassrls;
```

- **`BYPASSRLS` es CRÍTICO y es el gotcha #1 de todo el setup:** el snapshot
  inicial de PowerSync hace `SELECT`, que SÍ está sujeto a RLS. Las tablas de la
  app tienen RLS por `tenant_id` → un rol sin bypass ve **0 filas** → el snapshot
  baja casi nada y los clientes quedan clavados en "Esperando primera
  sincronización". La replicación por WAL no sufre RLS; es solo el snapshot.
- No usar el user `postgres` (mala higiene y su password no se comparte).
- **El pooler NO sirve** para este rol (`tenant/user not found`): la conexión del
  VPS va SIEMPRE al host directo (§2.4).

### 2.2 Publicación

La publicación define qué tablas puede replicar PowerSync (las sync rules después
eligen qué baja a quién). **NO usar `FOR ALL TABLES`** — lista explícita, la misma
del proyecto original (49 tablas al 2026-08-18):

```sql
create publication powersync for table
  app_dispositivos, cargos_extra, cliente_etiquetas, clientes, cobradores,
  comunidades, contrato_suspensiones, contratos, cuotas, dashboard_pins,
  data_op_backups, data_ops_log, departamentos, etiquetas, fotos_cliente,
  incidentes, inv_categorias, inv_movimientos, inv_productos, inv_proveedores,
  inv_seriales, inv_ubicaciones, modulos, municipios, notificaciones_mora,
  op_log, pagos, planes, recibo_correlativos, recibos, red_hubs, red_nodos,
  red_puertos, reinvite_locks, saldos_favor, settings, solicitudes_accion,
  super_admin_impersonation, sync_rechazos, tenant_modulos, tenants,
  ticket_adjuntos, ticket_eventos, ticket_materiales, ticket_tipos, tickets,
  visitas, whatsapp_credenciales, whatsapp_envios;
```

> **Regla permanente (Receta R10):** toda tabla nueva que deba sincronizar se
> agrega con `alter publication powersync add table <tabla>;` + su entrada en las
> sync rules. Si falta en la publicación, PowerSync no la ve NUNCA.

### 2.3 wal_level

Supabase ya viene con `wal_level = logical`. No hay que tocar nada; verificable
con `show wal_level;`.

### 2.4 Los 5 valores que "pasan" de Supabase al PowerSync

| # | Valor | De dónde sale | A dónde va (en el VPS) |
|---|---|---|---|
| 1 | Host directo de la DB: `db.<PROJECT_REF>.supabase.co:5432`, database `postgres` | fijo por convención de Supabase | `sync-config.yaml → replication.connections` |
| 2 | Usuario + password `powersync_selfhost` | lo creaste en §2.1 | ídem (password vía `.env` del compose, no en el yaml) |
| 3 | **CA de Supabase** (certificado raíz, contenido PEM) | Dashboard → Settings → Database → SSL / CA certificate | `sync-config.yaml → cacert` — ⚠️ quiere el CONTENIDO PEM inlineado, NO un path (con path da `SELF_SIGNED_CERT_IN_CHAIN`) |
| 4 | JWKS de Auth: `https://<PROJECT_REF>.supabase.co/auth/v1/.well-known/jwks.json` | fijo por convención | `sync-config.yaml → client_auth.jwks_uri` + `audience: [authenticated]` |
| 5 | Publicación `powersync` (§2.2) + `powersync/sync-rules.yaml` del repo | repo | `config/sync-config.yaml` del VPS |

> **Auth de clientes — cómo funciona:** la app NO usa un token especial. El
> `connector.dart` manda el **access token de la sesión Supabase** tal cual, y el
> PowerSync lo valida contra el JWKS público del proyecto (claves asimétricas
> ES256). Por eso no hay ningún secreto JWT que copiar: solo la URL del JWKS.
> (El `POWERSYNC_TOKEN_ENDPOINT` del `.env.json` es un vestigio: debe estar
> no-vacío para el check de configuración, pero el flujo actual no lo llama.)

---

## 3. El VPS con PowerSync self-hosted

Specs de referencia (las del original): Hetzner CX23 (2 vCPU / 4 GB / 40 GB,
~US$7/mes), Ubuntu 24.04, ufw (22/80/443) + fail2ban + SSH solo-llave.

1. **Docker con IPv6** — obligatorio: la conexión directa a la DB de Supabase es
   IPv6-only. `/etc/docker/daemon.json`:
   ```json
   { "ipv6": true, "ip6tables": true, "fixed-cidr-v6": "fd00:dead:beef::/64" }
   ```
   ⚠️ Una config IPv6 mala tumba dockerd y dispara el rate-limiter de systemd:
   `systemctl reset-failed docker` destraba.
2. **Stack en `/opt/powersync/`** (docker compose, 3 servicios):
   - `powersync`: imagen `journeyapps/powersync-service:1.23.3` (**pinear la
     versión**, no `latest`).
   - `pg-storage`: Postgres para el bucket-storage interno (sslmode disable, es
     local). Password autogenerada en `.env`.
   - `caddy`: HTTPS automático. Sin dominio propio, `https://<IP-con-guiones>.sslip.io`
     resuelve gratis y Caddy saca el certificado solo.
   - Secretos en `/opt/powersync/.env` (el compose los interpola):
     `PS_STORAGE_PASSWORD`, `PS_SUPABASE_DB_PASSWORD` (la de §2.1), `PS_ADMIN_TOKEN`.
3. **`config/sync-config.yaml`**: los 5 valores de §2.4 + copiar
   `powersync/sync-rules.yaml` del repo (formato `bucket_definitions`; el
   self-hosted lo soporta tal cual). Cambios de reglas después: editar el yaml
   en el VPS + `docker compose restart powersync` (puede disparar re-sync de
   los clientes — igual que pasaba con el cloud).
4. **Primer arranque — validar en orden:**
   - Log de `powersync`: conexión a Supabase OK y slot de replicación creado
     (`powersync_1_xxxx` en `select * from pg_replication_slots;` del lado Supabase).
   - **`snapshot_done: true`** con conteos que coincidan con la DB (clientes,
     cuotas, etc.). Si bajó ~0 filas → te faltó el `BYPASSRLS` (§2.1); el fix
     exige RE-SNAPSHOT: `docker compose down` + borrar el volumen del storage +
     `up` (y dropear el slot viejo con `pg_drop_replication_slot`).
   - Si la DB está quieta, el primer checkpoint necesita que el WAL avance:
     `select pg_logical_emit_message(true, 'powersync', 'nudge');`
   - Liveness: `curl https://<tu-url>/` → 200.
5. **Gotcha del ban:** si PowerSync reintenta con credenciales malas, Supabase
   **banea la IP** del VPS (anti fuerza-bruta). Se destraba en Dashboard →
   Settings → Database → **Network bans** → Unban (ojo: la IP baneada es la
   **IPv6 saliente** del server). Lección: no dejar el servicio en loop de
   reintentos con password equivocada.

---

## 4. La app (el tercer vértice)

`.env.json` en la raíz del repo (se hornea al build con `--dart-define-from-file`):

```json
{
  "SUPABASE_URL": "https://<PROJECT_REF>.supabase.co",
  "SUPABASE_ANON_KEY": "<anon key>",
  "POWERSYNC_URL": "https://<tu-vps>.sslip.io",
  "POWERSYNC_TOKEN_ENDPOINT": "no-usado-pero-requerido"
}
```

- `UPDATE_REPO` (opcional): canal de auto-update propio (`owner/repo` público de
  GitHub Releases). Sin la clave, apunta al canal por defecto del código.
- Rebuild completo tras cambiarlo (es build-time, no runtime).
- **NO** hace falta bumpear `_dbWipeVersion` para el cutover a un PowerSync
  nuevo: los clientes re-sincronizan solos contra el server nuevo (re-descarga
  única por dispositivo).

---

## 5. Checklist de verificación end-to-end

| # | Prueba | Esperado |
|---|---|---|
| 1 | Login en la app | entra (Auth va directo a Supabase, sin VPS) |
| 2 | Primera sincronización | baja el dataset completo; en el VPS los buckets se materializan AL conectar el primer cliente (antes se ven vacíos — normal, no es bug) |
| 3 | Cobro de prueba offline → online | sube a Supabase, el trigger recalcula la cuota, y la corrección BAJA por el sync a otro dispositivo |
| 4 | `supabase/tests/invariantes_dinero.sql` | todas las filas `violaciones = 0` |
| 5 | Apagar el VPS 5 min | la app sigue operando y subiendo; al volver el VPS, la bajada se reanuda sola |

---

## 6. Tabla rápida de gotchas (todos mordieron de verdad)

| Gotcha | Síntoma | Fix |
|---|---|---|
| Rol sin `BYPASSRLS` | snapshot ~0 filas, cliente en "Esperando primera sincronización" | §2.1 + re-snapshot (§3.4) |
| `cacert` como path | `SELF_SIGNED_CERT_IN_CHAIN` | inlinear el CONTENIDO PEM |
| Pooler en vez de host directo | `tenant/user not found` | `db.<ref>.supabase.co:5432` directo |
| Docker sin IPv6 | no conecta a Supabase (host directo es IPv6-only) | daemon.json de §3.1 |
| Reintentos con password mala | Supabase banea la IP del VPS | Network bans → Unban + corregir credencial |
| DB quieta tras arrancar | primer checkpoint no llega | `pg_logical_emit_message` (§3.4) |
| Tabla nueva no baja | falta en publicación y/o sync rules | `alter publication add table` + regla + restart |
| Imagen `latest` | upgrade sorpresa | pinear `:1.23.3` (o la validada) |
