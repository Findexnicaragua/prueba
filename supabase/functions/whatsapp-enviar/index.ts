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
// Plantillas de Meta — variables CON NOMBRE (named params). El admin crea la
// plantilla en Meta usando {{nombre}} {{monto}} {{dias}} {{empresa}}; el orden en
// el texto NO importa (cada parámetro se manda por nombre, no por posición).
//
// NO TESTEADO contra Meta (se construyó según la doc v21). El primer envío real
// lo hace Rubén con el botón "Probar". Deploy: manual en el Dashboard.

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
  phoneId: string;
  tplGracia: string;
  tplMora: string;
  lang: string;
  hora: number;
  empresa: string;
}

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

// Manda a UN cliente vía Meta y lo registra en whatsapp_envios. Devuelve {ok,error}.
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
    res = { ok: false, error: "Phone Number ID no configurado" };
  } else {
    const params: { name: string; text: string }[] = [
      { name: "nombre", text: cli.nombre },
      { name: "monto", text: fmtMonto(cli.monto) },
      { name: "dias", text: String(cli.dias) },
      { name: "empresa", text: cfg.empresa },
    ];
    try {
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
                parameters: params.map((p) => ({
                  type: "text",
                  parameter_name: p.name,
                  text: p.text,
                })),
              }],
            },
          }),
        },
      );
      if (!resp.ok) {
        const t = await resp.text();
        res = { ok: false, error: `Meta ${resp.status}: ${t.slice(0, 300)}` };
      } else {
        res = { ok: true };
      }
    } catch (e) {
      res = { ok: false, error: `Red: ${String(e).slice(0, 200)}` };
    }
  }
  await admin.from("whatsapp_envios").insert({
    tenant_id: tenantId,
    cliente_id: cli.cliente_id,
    estado: cli.estado,
    canal: "api",
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

    // ── modo LOTE (cron): auth por service key ───────────────────────────────
    if (modo === "lote") {
      const authHeader = req.headers.get("Authorization") ?? "";
      if (authHeader !== `Bearer ${service}`) {
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
