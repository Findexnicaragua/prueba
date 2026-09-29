// Edge Function: whatsapp-enviar
//
// Manda mensajes por la Cloud API de Meta (modo PAGO). Dos modos:
//   - modo "uno"  (caller super_admin): envía al PRIMER cliente elegible del
//     tenant — el botón "Probar con un cliente" del panel. Confirma que el
//     pipeline (token + plantilla + número) funciona antes de confiar en el cron.
//   - modo "lote" (caller = service role, lo llama el CRON): por cada tenant con
//     el modo API activo + token cargado + cuya hora configurada == la hora
//     actual (Nicaragua), busca los clientes a notificar (función Postgres
//     `whatsapp_clientes_a_notificar`, que respeta la frecuencia + el tope) y
//     manda a cada uno. Registra cada envío en `whatsapp_envios`.
//
// DOS PROVEEDORES, elegibles por tenant vía `cobranza.notif_api_proveedor` (0235).
// Lo único que cambia es cómo se arma el pedido de salida; a quién se le avisa,
// la frecuencia, el tope y el log son compartidos.
//
//   · meta      → POST graph.facebook.com/<v>/<phoneId>/messages. Token en header
//                 Bearer. Variables CON NOMBRE: la plantilla usa {{nombre}}
//                 {{monto}} {{dias}} {{empresa}} y el orden en el texto NO importa.
//                 Éxito = HTTP 2xx.
//   · whatchimp → POST app.whatchimp.com/api/v1/whatsapp/send. Token como
//                 parámetro `apiToken`. Variables POSICIONALES: la plantilla usa
//                 {{1}}..{{4}} en el orden de ORDEN_VARIABLES. Éxito = `status`
//                 == "1" EN EL BODY (devuelve HTTP 200 aunque falle).
//
// Las plantillas NO son intercambiables entre proveedores: cada una se carga del
// lado del proveedor elegido y con SU forma de variable.
//
// NO TESTEADO contra Meta (se construyó según la doc v21) ni contra WhatChimp
// (según su doc de feb-2026). El primer envío real lo hace Rubén con el botón
// "Probar". Deploy: manual en el Dashboard.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import { corsHeaders, jsonError } from "../_shared/response.ts";

const META_VERSION = "v21.0";
const SYSTEM_TENANT = "00000000-0000-0000-0000-000000000000";

interface Cliente {
  cliente_id: string;
  nombre: string;
  telefono: string;
  estado: string; // 'gracia' | 'mora'
  monto: number;
  dias: number;
}

interface Cfg {
  habilitado: boolean;
  tokenSet: boolean;
  proveedor: string; // 'meta' | 'whatchimp' — ver 0235
  phoneId: string;
  tplGracia: string;
  tplMora: string;
  lang: string;
  hora: number;
  empresa: string;
}

// Los 4 datos que se interpolan en la plantilla, SIEMPRE en este orden. Meta los
// manda por nombre y WhatChimp por posición (variable1..4), así que el orden de
// esta lista ES el contrato con las plantillas de WhatChimp: cambiarlo acá sin
// reescribir las plantillas del proveedor manda el monto donde va el nombre.
const ORDEN_VARIABLES = ["nombre", "monto", "dias", "empresa"] as const;

// Teléfono internacional (Nicaragua 505). 8 dígitos → 505+; si ya trae código
// (≠ 8 dígitos) se deja. Igual que phoneWhatsappIntl del cliente Dart.
function phoneIntl(s: string): string {
  const d = (s ?? "").replace(/\D/g, "");
  return d.length === 8 ? "505" + d : d;
}

function fmtMonto(monto: number): string {
  try {
    return new Intl.NumberFormat("es-NI", {
      style: "currency",
      currency: "NIO",
      minimumFractionDigits: 2,
    }).format(Number(monto));
  } catch {
    return "C$ " + Number(monto).toFixed(2);
  }
}

async function getConfig(admin: SupabaseClient, tenantId: string): Promise<Cfg> {
  const { data } = await admin.from("settings")
    .select("clave, valor")
    .eq("tenant_id", tenantId)
    .in("clave", [
      "cobranza.notif_api_habilitado",
      "cobranza.notif_api_proveedor",
      "cobranza.notif_api_phone_id",
      "cobranza.notif_api_template_gracia",
      "cobranza.notif_api_template_mora",
      "cobranza.notif_api_template_lang",
      "cobranza.notif_api_hora",
      "cobranza.notif_api_token_configurado",
      "empresa.nombre",
    ]);
  const m: Record<string, unknown> = {};
  for (const row of data ?? []) {
    try { m[row.clave] = JSON.parse(row.valor); } catch { m[row.clave] = row.valor; }
  }
  return {
    habilitado: m["cobranza.notif_api_habilitado"] === true,
    tokenSet: m["cobranza.notif_api_token_configurado"] === true,
    // Sin setting (tenant viejo, antes de 0235) = meta, que era el único camino.
    proveedor: String(m["cobranza.notif_api_proveedor"] ?? "meta"),
    phoneId: String(m["cobranza.notif_api_phone_id"] ?? ""),
    tplGracia: String(m["cobranza.notif_api_template_gracia"] ?? ""),
    tplMora: String(m["cobranza.notif_api_template_mora"] ?? ""),
    lang: String(m["cobranza.notif_api_template_lang"] ?? "es"),
    hora: Number(m["cobranza.notif_api_hora"] ?? 8),
    empresa: String(m["empresa.nombre"] ?? ""),
  };
}

async function getToken(admin: SupabaseClient, tenantId: string): Promise<string | null> {
  const { data } = await admin.from("whatsapp_credenciales")
    .select("access_token").eq("tenant_id", tenantId).maybeSingle();
  return data?.access_token ?? null;
}

// Los valores a interpolar, indexados por el nombre de ORDEN_VARIABLES.
function valoresDe(cfg: Cfg, cli: Cliente): Record<string, string> {
  return {
    nombre: cli.nombre,
    monto: fmtMonto(cli.monto),
    dias: String(cli.dias),
    empresa: cfg.empresa,
  };
}

// Cloud API de Meta, directo. Variables CON NOMBRE: el orden en el texto de la
// plantilla no importa. Éxito = HTTP 2xx.
async function enviarPorMeta(
  cfg: Cfg,
  token: string,
  cli: Cliente,
  template: string,
): Promise<{ ok: boolean; error?: string }> {
  const v = valoresDe(cfg, cli);
  const resp = await fetch(
    `https://graph.facebook.com/${META_VERSION}/${cfg.phoneId}/messages`,
    {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${token}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        messaging_product: "whatsapp",
        to: phoneIntl(cli.telefono),
        type: "template",
        template: {
          name: template,
          language: { code: cfg.lang },
          components: [{
            type: "body",
            parameters: ORDEN_VARIABLES.map((k) => ({
              type: "text",
              parameter_name: k,
              text: v[k],
            })),
          }],
        },
      }),
    },
  );
  if (!resp.ok) {
    const t = await resp.text();
    return { ok: false, error: `Meta ${resp.status}: ${t.slice(0, 300)}` };
  }
  return { ok: true };
}

// WhatChimp. Cuatro diferencias con Meta que obligan a este camino aparte:
//   1. El token va como PARÁMETRO (`apiToken`), no como header Bearer. La doc lo
//      muestra por GET en la query string; se manda por POST a propósito, para
//      que la clave no quede escrita en logs de proxies ni de servidores.
//   2. Las variables son POSICIONALES (variable1..N → {{1}}..{{N}}), no con
//      nombre. El orden sale de ORDEN_VARIABLES.
//   3. Devuelve HTTP 200 aunque falle: el resultado real viene en `status`, que
//      es el STRING "1" (éxito) o "0". Mirar solo resp.ok da falsos éxitos.
//   4. Las plantillas van a `/send/template` con `template_id` = el ID INTERNO
//      de WhatChimp (no el nombre, no el ID de Meta). `/send` a secas es SOLO
//      texto de sesión: ignora los campos de plantilla y rechaza fuera de la
//      ventana de 24h ("outside 24 hour window") — descubierto probando la API
//      real el 2026-08-18; su doc de feb-2026 no documentaba /send/template.
//      El ID se resuelve por nombre vía `/template/list` (campo `id`), cacheado
//      por invocación, así el setting sigue siendo el NOMBRE (lo que ve el user).

const _tplCache = new Map<string, Record<string, string>>();

async function whatchimpTemplateId(
  token: string,
  phoneId: string,
  nombre: string,
): Promise<string | null> {
  let mapa = _tplCache.get(phoneId);
  if (!mapa) {
    const form = new URLSearchParams();
    form.set("apiToken", token);
    form.set("phone_number_id", phoneId);
    const resp = await fetch(
      "https://app.whatchimp.com/api/v1/whatsapp/template/list",
      {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: form.toString(),
      },
    );
    if (!resp.ok) return null;
    let json: { message?: unknown };
    try {
      json = JSON.parse(await resp.text());
    } catch {
      return null;
    }
    const items = Array.isArray(json.message)
      ? json.message
      : (json.message && typeof json.message === "object")
      ? [json.message]
      : [];
    mapa = {};
    for (const it of items as Array<Record<string, unknown>>) {
      const nom = typeof it.template_name === "string" ? it.template_name : "";
      const id = it.id != null ? String(it.id) : "";
      if (nom && id) mapa[nom] = id;
    }
    _tplCache.set(phoneId, mapa);
  }
  return mapa[nombre] ?? null;
}

async function enviarPorWhatchimp(
  cfg: Cfg,
  token: string,
  cli: Cliente,
  template: string,
): Promise<{ ok: boolean; error?: string }> {
  const tplId = await whatchimpTemplateId(token, cfg.phoneId, template);
  if (!tplId) {
    return {
      ok: false,
      error: `WhatChimp: la plantilla "${template}" no existe en la cuenta ` +
        `(verificá el nombre en Bot Manager → Message Templates)`,
    };
  }
  const v = valoresDe(cfg, cli);
  const form = new URLSearchParams();
  form.set("apiToken", token);
  form.set("phone_number_id", cfg.phoneId);
  form.set("phone_number", phoneIntl(cli.telefono));
  form.set("template_id", tplId);
  form.set("language_code", cfg.lang);
  ORDEN_VARIABLES.forEach((k, i) => form.set(`variable${i + 1}`, v[k]));

  const resp = await fetch(
    "https://app.whatchimp.com/api/v1/whatsapp/send/template",
    {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: form.toString(),
    },
  );
  const texto = await resp.text();
  if (!resp.ok) {
    return { ok: false, error: `WhatChimp ${resp.status}: ${texto.slice(0, 300)}` };
  }
  let json: { status?: unknown; message?: unknown };
  try {
    json = JSON.parse(texto);
  } catch {
    return { ok: false, error: `WhatChimp: respuesta ilegible: ${texto.slice(0, 200)}` };
  }
  if (String(json.status) !== "1") {
    const msg = typeof json.message === "string" ? json.message : texto.slice(0, 200);
    return { ok: false, error: `WhatChimp: ${msg}` };
  }
  return { ok: true };
}

// Manda a UN cliente por el proveedor del tenant y lo registra en
// whatsapp_envios. Devuelve {ok,error}. El log es igual para los dos.
async function enviarUno(
  admin: SupabaseClient,
  tenantId: string,
  cfg: Cfg,
  token: string,
  cli: Cliente,
): Promise<{ ok: boolean; error?: string }> {
  const template = cli.estado === "mora" ? cfg.tplMora : cfg.tplGracia;
  let res: { ok: boolean; error?: string };
  if (!template) {
    res = { ok: false, error: `Plantilla de "${cli.estado}" no configurada` };
  } else if (!cfg.phoneId) {
    res = { ok: false, error: "Falta el ID del número" };
  } else {
    try {
      res = cfg.proveedor === "whatchimp"
        ? await enviarPorWhatchimp(cfg, token, cli, template)
        : await enviarPorMeta(cfg, token, cli, template);
    } catch (e) {
      res = { ok: false, error: `Red: ${String(e).slice(0, 200)}` };
    }
  }
  await admin.from("whatsapp_envios").insert({
    tenant_id: tenantId,
    cliente_id: cli.cliente_id,
    estado: cli.estado,
    // Queda por dónde salió: al depurar un fallo, saber si fue Meta o WhatChimp
    // es lo primero que se pregunta. Sigue empezando con "api" para distinguirlo
    // del wa.me manual (`like 'api%'`).
    canal: `api:${cfg.proveedor}`,
    ok: res.ok,
    error: res.error ?? null,
  });
  return res;
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  try {
    const url = Deno.env.get("SUPABASE_URL")!;
    const anon = Deno.env.get("SUPABASE_ANON_KEY")!;
    const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const admin = createClient(url, service, {
      auth: { autoRefreshToken: false, persistSession: false },
    });

    const body = await req.json().catch(() => ({}));
    const modo = body.modo ?? "uno";

    // ── modo LOTE (cron): auth por service key O por CRON_SECRET ─────────────
    if (modo === "lote") {
      // La igualdad contra SUPABASE_SERVICE_ROLE_KEY dejó de ser confiable:
      // tras la migración de claves de Supabase (2026-08), el env de la función
      // puede traer una variante distinta de la service key activa y el string
      // nunca matchea. CRON_SECRET (secret propio, `supabase secrets set`) es
      // nuestro y no rota con la plataforma. El Authorization igual debe llevar
      // un JWT válido para pasar el gateway; la autorización REAL es el secret.
      const authHeader = req.headers.get("Authorization") ?? "";
      const cronSecret = Deno.env.get("CRON_SECRET") ?? "";
      const porServiceKey = authHeader === `Bearer ${service}`;
      const porCronSecret = cronSecret !== "" &&
        (req.headers.get("x-cron-secret") ?? "") === cronSecret;
      if (!porServiceKey && !porCronSecret) {
        return jsonError("No autorizado (lote requiere service role)", 401);
      }
      // Hora actual Nicaragua (UTC-6, sin DST).
      const horaNica = (new Date().getUTCHours() - 6 + 24) % 24;
      const { data: tenants } = await admin.from("tenants").select("id")
        .neq("id", SYSTEM_TENANT);
      let enviados = 0, fallidos = 0, tenantsProcesados = 0;
      for (const t of tenants ?? []) {
        const cfg = await getConfig(admin, t.id);
        if (!cfg.habilitado || !cfg.tokenSet || cfg.hora !== horaNica) continue;
        const token = await getToken(admin, t.id);
        if (!token) continue;
        tenantsProcesados++;
        const { data: clientes } = await admin
          .rpc("whatsapp_clientes_a_notificar", { p_tenant: t.id });
        for (const cli of (clientes ?? []) as Cliente[]) {
          const r = await enviarUno(admin, t.id, cfg, token, cli);
          if (r.ok) enviados++; else fallidos++;
        }
      }
      return new Response(
        JSON.stringify({ ok: true, tenantsProcesados, enviados, fallidos }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 200 },
      );
    }

    // ── modo UNO (test, super_admin) ─────────────────────────────────────────
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) return jsonError("Authorization header faltante", 401);
    const caller = createClient(url, anon, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: { user } } = await caller.auth.getUser();
    if (!user) return jsonError("Sesión inválida", 401);
    const { data: yo } = await caller
      .from("cobradores").select("rol").eq("id", user.id).single();
    if (!yo || yo.rol !== "super_admin") {
      return jsonError("Solo el super_admin puede probar el envío", 403);
    }
    const tenantId: string = body.tenant_id;
    if (!tenantId) return jsonError("tenant_id requerido", 400);

    const cfg = await getConfig(admin, tenantId);
    if (!cfg.tokenSet) return jsonError("Falta cargar el Access Token", 400);
    const token = await getToken(admin, tenantId);
    if (!token) return jsonError("Token no encontrado en el servidor", 400);

    const { data: clientes } = await admin
      .rpc("whatsapp_clientes_a_notificar", { p_tenant: tenantId });
    const lista = (clientes ?? []) as Cliente[];
    if (lista.length === 0) {
      return jsonError("No hay clientes elegibles para probar ahora", 400);
    }
    const cli = lista[0];
    const r = await enviarUno(admin, tenantId, cfg, token, cli);
    if (!r.ok) return jsonError(r.error ?? "Falló el envío", 400);
    return new Response(
      JSON.stringify({ ok: true, enviado_a: cli.nombre }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 200 },
    );
  } catch (e) {
    console.error("whatsapp-enviar: error", e);
    return jsonError("Error interno", 500);
  }
});
