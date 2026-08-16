// Edge Function: cambiar-email-cobrador
//
// Permite al super_admin cambiar el email de un miembro de cualquier
// tenant. Útil cuando alguien cambia de empresa, hace typo al invitar,
// o el dominio del email cambia.
//
// Comportamiento:
//   - Llama auth.admin.updateUserById con email_confirm:true para que
//     el nuevo email quede confirmado de una sin re-verificación.
//   - El super_admin es responsable de notificar al usuario por canal
//     fuera-de-banda (la app no manda email de notificación al viejo).
//
// Guards:
//   - Sólo super_admin.
//   - No se modifica a sí mismo.
//   - No se modifica a otro super_admin.
//   - Sólo a usuarios con email_confirmed_at != null (confirmados); para
//     pending invites el flujo correcto es 'Reenviar invitación' con el
//     email corregido.
//   - El nuevo email tiene que pasar validación regex básica.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import { corsHeaders, jsonError } from "../_shared/response.ts";
import { humanizeAuthError } from "../_shared/auth_errors.ts";

interface CambiarEmailRequest {
  cobrador_id: string;
  nuevo_email: string;
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return jsonError("Authorization header faltante", 401);
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

    const callerClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
    });

    const { data: { user } } = await callerClient.auth.getUser();
    if (!user) return jsonError("Sesión inválida", 401);

    const { data: yo, error: yoErr } = await callerClient
      .from("cobradores")
      .select("rol")
      .eq("id", user.id)
      .single();
    if (yoErr || !yo) {
      return jsonError("No estás en la tabla cobradores", 403);
    }
    if (yo.rol !== "super_admin") {
      return jsonError("Sólo super_admin puede cambiar emails", 403);
    }

    const body: CambiarEmailRequest = await req.json();
    if (!body.cobrador_id || !body.nuevo_email) {
      return jsonError(
        "cobrador_id y nuevo_email son requeridos",
        400,
      );
    }

    // Normalizar: Supabase guarda emails en lowercase, así la idempotencia
    // y comparaciones quedan consistentes. Trim por si el cliente mandó
    // espacios extra.
    const nuevoEmail = body.nuevo_email.trim().toLowerCase();
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(nuevoEmail)) {
      return jsonError("Email inválido", 400);
    }

    if (body.cobrador_id === user.id) {
      return jsonError(
        "No podés cambiar tu propio email desde acá",
        400,
      );
    }

    const admin = createClient(supabaseUrl, serviceKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });

    // Lookup del target — necesitamos saber el email actual + tenant para
    // el audit + verificar que no sea pending ni super_admin.
    const { data: targetUserData, error: targetErr } = await admin.auth.admin
      .getUserById(body.cobrador_id);
    if (targetErr) {
      console.error("cambiar-email: getUserById falló", targetErr);
      return jsonError("Error interno", 500);
    }
    const targetUser = targetUserData?.user;
    if (!targetUser) return jsonError("Usuario no existe", 404);

    if (!targetUser.email_confirmed_at) {
      return jsonError(
        "El usuario no aceptó la invitación. Usá 'Reenviar invitación' " +
          "con el email correcto en vez de cambiarlo acá.",
        400,
      );
    }

    const emailAnterior = targetUser.email;
    if ((emailAnterior ?? "").toLowerCase() === nuevoEmail) {
      // Idempotencia: si ya tiene ese email (comparado case-insensitive
      // porque Supabase guarda en lowercase), no hacemos nada.
      return new Response(
        JSON.stringify({
          ok: true,
          message: "El email ya era el mismo",
        }),
        {
          headers: { ...corsHeaders, "Content-Type": "application/json" },
          status: 200,
        },
      );
    }

    const { data: tc, error: tcErr } = await admin
      .from("cobradores")
      .select("tenant_id, rol")
      .eq("id", body.cobrador_id)
      .maybeSingle();
    if (tcErr) {
      console.error("cambiar-email: cobrador lookup falló", tcErr);
      return jsonError("Error interno", 500);
    }
    if (!tc) return jsonError("Cobrador no existe", 404);

    if (tc.rol === "super_admin") {
      return jsonError(
        "No se puede modificar el email de otro super_admin",
        400,
      );
    }

    // Pre-flight: chequear que el nuevo email no esté ya tomado por
    // OTRO usuario distinto al target, para devolver un error claro antes
    // de intentar el update.
    //
    // Usa RPC SECURITY DEFINER que consulta auth.users directamente.
    // Reemplaza el viejo listUsers({ perPage: 1000 }) que tenía tope
    // de 1000 users y daba falsos negativos con más.
    const { data: emailExists, error: lookupErr } = await admin.rpc(
      "check_email_exists_in_auth",
      { p_email: nuevoEmail, p_exclude_user_id: body.cobrador_id },
    );
    if (lookupErr) {
      console.error("cambiar-email: check_email_exists falló", lookupErr);
      return jsonError("Error interno", 500);
    }
    if (emailExists) {
      return jsonError(
        "Ese email ya está registrado en otro usuario. Elegí otro o, " +
          "si es del mismo usuario, contactá soporte.",
        400,
      );
    }

    // Actualizar email + mantener confirmado (no re-verificación).
    const { error: updErr } = await admin.auth.admin.updateUserById(
      body.cobrador_id,
      { email: nuevoEmail, email_confirm: true },
    );
    if (updErr) {
      console.error(
        "cambiar-email: updateUserById falló. " +
          `cobrador_id=${body.cobrador_id}.`,
        updErr,
      );
      return jsonError(humanizeAuthError(updErr.message), 400);
    }

    // Invalidar todas las sesiones del target — sino sigue logueado con
    // JWT del email viejo hasta el siguiente refresh (~1h). Para un cambio
    // de identidad mejor forzamos re-login en todos los devices.
    const { error: signOutErr } = await admin.auth.admin.signOut(
      body.cobrador_id,
      "global",
    );
    if (signOutErr) {
      // No bloqueamos — el email ya cambió. Pero el target mantiene su JWT
      // viejo hasta ~1h.
      console.error("cambiar-email: signOut global falló", signOutErr);
    }

    return new Response(
      JSON.stringify({
        ok: true,
        message: "Email actualizado",
      }),
      {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 200,
      },
    );
  } catch (e) {
    // Scrub por consistencia con crear-tenant / reenviar-invitacion /
    // invitar-cobrador. Acá no hay password generada en scope, pero
    // `nuevoEmail` (PII) sí, y los logs del Dashboard son consultables.
    const safeMessage = e instanceof Error ? e.message : String(e);
    console.error("cambiar-email-cobrador: unhandled", safeMessage);
    return jsonError("Error interno", 500);
  }
});
