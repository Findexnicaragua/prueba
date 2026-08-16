// Edge Function: forzar-password-cobrador
//
// Permite asignar directamente una contraseña a otro usuario, sin pasar por
// el flujo de email (útil cuando el cliente no tiene acceso al email o cuando
// hay rate limits). Quien fuerza comunica la contraseña por canal seguro
// (Whatsapp, en persona).
//
// Callers permitidos:
//   - super_admin: puede forzar a cualquier usuario (sujeto a los guards).
//   - admin: puede forzar SOLO a usuarios de SU MISMO tenant que NO sean
//     admin ni super_admin (un admin no resetea a otro admin ni al super).
//
// Guards:
//   - Caller debe ser super_admin o admin (rol en cobradores).
//   - No puede modificarse a sí mismo.
//   - No puede modificar a otro super_admin.
//   - admin: el target debe ser de su mismo tenant y de rol cobrador o
//     admin_cobranza (NO admin, NO super_admin).
//   - No puede modificar a nadie del tenant System (defensa en profundidad).
//   - Password mínimo 8 caracteres (alineado con default de Supabase).
//
// Tras actualizar la password invalida las sesiones activas del target
// (signOut global) para forzar re-login con la credencial nueva.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import { corsHeaders, jsonError } from "../_shared/response.ts";
import { humanizeAuthError } from "../_shared/auth_errors.ts";

// Tenant fijo "System" (donde vive el super_admin). Nadie de este tenant puede
// ser target de un force-password, aun si por un bug su rol no fuese super_admin.
const SYSTEM_TENANT = "00000000-0000-0000-0000-000000000000";

interface ForzarPasswordRequest {
  cobrador_id: string;
  nueva_password: string;
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

    // Cliente con el JWT del caller — para identificar quién está pidiendo.
    const callerClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
    });

    const { data: { user } } = await callerClient.auth.getUser();
    if (!user) return jsonError("Sesión inválida", 401);

    // Verificar el rol y el tenant del caller. Necesitamos el tenant_id
    // para validar el scope cuando el caller es admin (sólo su tenant).
    const { data: yo, error: yoErr } = await callerClient
      .from("cobradores")
      .select("rol, tenant_id")
      .eq("id", user.id)
      .single();
    if (yoErr || !yo) {
      return jsonError("No estás en la tabla cobradores", 403);
    }
    const callerEsSuperAdmin = yo.rol === "super_admin";
    const callerEsAdmin = yo.rol === "admin";
    if (!callerEsSuperAdmin && !callerEsAdmin) {
      return jsonError(
        "Sólo admin o super_admin puede forzar contraseñas",
        403,
      );
    }

    // Validar body.
    const body: ForzarPasswordRequest = await req.json();
    if (!body.cobrador_id || !body.nueva_password) {
      return jsonError(
        "cobrador_id y nueva_password son requeridos",
        400,
      );
    }
    if (body.nueva_password.length < 8) {
      return jsonError(
        "La contraseña debe tener al menos 8 caracteres",
        400,
      );
    }

    if (body.cobrador_id === user.id) {
      return jsonError(
        "No podés forzar tu propia contraseña — usá el flujo normal",
        400,
      );
    }

    // Cliente con service_role para validar target + auth.admin.update.
    const admin = createClient(supabaseUrl, serviceKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });

    const { data: target, error: tgtErr } = await admin
      .from("cobradores")
      .select("id, tenant_id, rol")
      .eq("id", body.cobrador_id)
      .maybeSingle();
    if (tgtErr) {
      // No filtramos el mensaje del DB al cliente — log server-side y
      // mensaje genérico afuera.
      console.error("forzar-password: tenant lookup failed", tgtErr);
      return jsonError("Error interno verificando el usuario", 500);
    }
    if (!target) return jsonError("Cobrador no existe", 404);
    if (target.rol === "super_admin") {
      return jsonError(
        "No se puede modificar la contraseña de otro super_admin",
        400,
      );
    }
    // Scope del admin: sólo puede forzar a usuarios de SU MISMO tenant y que
    // sean cobrador o admin_cobranza. NO puede resetear a otro admin (par) ni
    // al super_admin (ya bloqueado arriba). El super_admin no tiene estas
    // restricciones (gestión cross-tenant legítima).
    if (callerEsAdmin) {
      if (target.tenant_id !== yo.tenant_id) {
        return jsonError(
          "No podés forzar la contraseña de un usuario de otro tenant",
          403,
        );
      }
      if (target.rol === "admin") {
        return jsonError(
          "Un admin no puede forzar la contraseña de otro admin",
          403,
        );
      }
    }
    // Defensa en profundidad: nadie del tenant System puede ser target, aunque
    // su rol no sea super_admin (protege contra un estado inválido futuro de un
    // usuario en el tenant del sistema). El guard de rol de arriba es la línea
    // principal; este es el cinturón extra.
    if (target.tenant_id === SYSTEM_TENANT) {
      return jsonError(
        "No se puede modificar la contraseña de un usuario del sistema",
        400,
      );
    }

    // Actualizar password vía auth.admin (única vía sin email).
    const { error: updErr } = await admin.auth.admin.updateUserById(
      body.cobrador_id,
      { password: body.nueva_password },
    );
    if (updErr) {
      console.error(
        "forzar-password: updateUserById falló. " +
          `cobrador_id=${body.cobrador_id}.`,
        updErr,
      );
      return jsonError(humanizeAuthError(updErr.message), 400);
    }

    // Almacenar la nueva contraseña en password_texto para que el admin
    // pueda consultarla después (ver-password-cobrador).
    await admin.from("cobradores")
      .update({ password_texto: body.nueva_password })
      .eq("id", body.cobrador_id);

    // Invalidar todas las sesiones activas del target.
    const { error: signOutErr } = await admin.auth.admin.signOut(
      body.cobrador_id,
      "global",
    );
    if (signOutErr) {
      // No bloqueamos — la password ya cambió. Pero el target mantiene
      // su JWT viejo válido hasta ~1h (expiración natural).
      console.error(
        "forzar-password: global signOut failed",
        signOutErr,
      );
    }

    return new Response(
      JSON.stringify({
        ok: true,
        message: "Contraseña actualizada",
      }),
      {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 200,
      },
    );
  } catch (e) {
    // Errores no anticipados (parseo JSON inválido, network, etc.).
    console.error("forzar-password: unhandled error", e);
    return jsonError("Error interno", 500);
  }
});
