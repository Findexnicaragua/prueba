// Edge Function: whatsapp-set-token
//
// Guarda el Access Token de la Cloud API de Meta para un tenant. El token es un
// SECRETO (puede mandar mensajes facturados + suplantar el negocio), así que NO
// va en `settings` (que sincroniza a los dispositivos) — va en la tabla
// server-only `whatsapp_credenciales`, escrita SOLO por esta función con el
// service role. Refleja en el setting sincronizado `notif_api_token_configurado`
// para que la UI muestre "configurado" sin exponer el token.
//
// Caller: SOLO super_admin (configura el modo API por tenant).

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import { corsHeaders, jsonError } from "../_shared/response.ts";

interface Body {
  tenant_id: string;
  access_token: string;
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) return jsonError("Authorization header faltante", 401);

    const url = Deno.env.get("SUPABASE_URL")!;
    const anon = Deno.env.get("SUPABASE_ANON_KEY")!;
    const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

    const caller = createClient(url, anon, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: { user } } = await caller.auth.getUser();
    if (!user) return jsonError("Sesión inválida", 401);

    const { data: yo } = await caller
      .from("cobradores").select("rol").eq("id", user.id).single();
    if (!yo || yo.rol !== "super_admin") {
      return jsonError("Solo el super_admin puede configurar la API", 403);
    }

    const body: Body = await req.json();
    if (!body.tenant_id || !body.access_token) {
      return jsonError("tenant_id y access_token son requeridos", 400);
    }

    const admin = createClient(url, service, {
      auth: { autoRefreshToken: false, persistSession: false },
    });

    const { error: upErr } = await admin.from("whatsapp_credenciales").upsert({
      tenant_id: body.tenant_id,
      access_token: body.access_token,
      actualizado_en: new Date().toISOString(),
    });
    if (upErr) {
      console.error("whatsapp-set-token: upsert falló", upErr);
      return jsonError("No se pudo guardar el token", 500);
    }

    // Reflejar en el setting sincronizado (valor TEXT-JSON: "true"). Si la fila
    // no existe (tenant viejo sin backfill / race con el seed), el UPDATE afecta
    // 0 filas → quedaría el token cargado pero la UI mostrándolo como NO
    // configurado. Por eso: update, y si no tocó nada, insert.
    const { data: reflej } = await admin.from("settings")
      .update({ valor: "true" })
      .eq("tenant_id", body.tenant_id)
      .eq("clave", "cobranza.notif_api_token_configurado")
      .select("id");
    if (!reflej || reflej.length === 0) {
      await admin.from("settings").insert({
        tenant_id: body.tenant_id,
        clave: "cobranza.notif_api_token_configurado",
        valor: "true",
        tipo: "boolean",
        categoria: "cobranza",
        descripcion: "Refleja si el Access Token está cargado",
        editable_por: "super_admin",
      });
    }

    // Ecoar el nombre del tenant para que la UI confirme a QUIÉN se le cargó el
    // token (evita pegarlo en el tenant equivocado — manda mensajes facturados).
    const { data: ten } = await admin.from("tenants")
      .select("nombre").eq("id", body.tenant_id).maybeSingle();

    return new Response(JSON.stringify({ ok: true, tenant: ten?.nombre ?? null }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 200,
    });
  } catch (e) {
    console.error("whatsapp-set-token: error", e);
    return jsonError("Error interno", 500);
  }
});
