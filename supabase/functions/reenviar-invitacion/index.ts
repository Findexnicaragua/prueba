// Edge Function: reenviar-invitacion
//
// Re-envía la invitación a un usuario que aún no completó el signup
// (email_confirmed_at IS NULL). El link original puede haber expirado
// o haberse perdido en spam.
//
// Implementación pragmática: borra el usuario y lo re-crea con la
// misma metadata. Para pending invites es seguro — la row de cobradores
// cascadea por la FK, no hay clientes asignados aún, no hay pagos /
// recibos huérfanos. La fila se recrea limpia al re-aceptar.
//
// Dos modos según `enviar_email`:
//   - true (default) → inviteUserByEmail (manda email nuevo).
//   - false          → createUser con password aleatoria + email_confirm=true
//                      (no manda nada; devuelve nueva_password para que
//                      el caller la comparta por otro canal). Útil
//                      cuando SMTP está en sandbox y el destinatario
//                      no recibe email automatizado.
//
// Guards:
//   - Sólo super_admin o admin (rol en cobradores).
//   - Admin sólo puede reenviar a usuarios de SU mismo tenant.
//   - El target debe estar en pending (email_confirmed_at IS NULL); si
//     ya aceptó, devolvemos error y se sugiere 'Reset password vía email'.
//   - super_admin no puede reenviar invitaciones a otros super_admin.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import { corsHeaders, jsonError } from "../_shared/response.ts";
import { humanizeAuthError } from "../_shared/auth_errors.ts";
import { generarPasswordSegura } from "../_shared/passwords.ts";

interface ReenviarRequest {
  cobrador_id: string;
  redirect_to?: string;
  // Si false: createUser con password aleatoria, devuelve nueva_password.
  // Default true: inviteUserByEmail con el redirect_to del caller.
  enviar_email?: boolean;
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  // #6: lock anti-race por cobrador. Se asigna al tomar el lock (captura `admin`
  // y `body`) y se libera en el finally, pase lo que pase.
  let releaseLock: (() => Promise<void>) | null = null;

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

    // Verificar caller en cobradores.
    const { data: yo, error: yoErr } = await callerClient
      .from("cobradores")
      .select("tenant_id, rol")
      .eq("id", user.id)
      .single();
    if (yoErr || !yo) {
      return jsonError("No estás en la tabla cobradores", 403);
    }

    const callerEsSuperAdmin = yo.rol === "super_admin";
    const callerEsAdmin = yo.rol === "admin";
    if (!callerEsSuperAdmin && !callerEsAdmin) {
      return jsonError(
        "Sólo admin o super_admin puede reenviar invitaciones",
        403,
      );
    }

    const body: ReenviarRequest = await req.json();
    if (!body.cobrador_id) {
      return jsonError("cobrador_id requerido", 400);
    }

    // Cliente service_role para inspeccionar auth.users y borrar/invitar.
    const admin = createClient(supabaseUrl, serviceKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });

    // #6: tomar el lock por cobrador (anti-race de 2 super_admins reenviando el
    // mismo pendiente). Limpia locks huérfanos (>30s) y trata de insertar; PK
    // duplicada = otro reenvío en curso → 409. Se libera en el finally.
    // TTL 120s: holgado para el peor caso real del path (deleteUser +
    // inviteUserByEmail/createUser + envío de email = 2 round-trips a Auth).
    await admin
      .from("reinvite_locks")
      .delete()
      .lt("locked_at", new Date(Date.now() - 120000).toISOString());
    const { error: lockErr } = await admin
      .from("reinvite_locks")
      .insert({ cobrador_id: body.cobrador_id });
    if (lockErr) {
      return jsonError(
        "Otro reenvío de esta invitación está en curso. Esperá unos " +
          "segundos y refrescá la lista.",
        409,
      );
    }
    releaseLock = async () => {
      await admin
        .from("reinvite_locks")
        .delete()
        .eq("cobrador_id", body.cobrador_id);
    };

    // Obtener el target user (auth.users).
    const { data: targetUserData, error: targetErr } = await admin.auth.admin
      .getUserById(body.cobrador_id);
    if (targetErr) {
      console.error("reenviar: getUserById falló", targetErr);
      return jsonError("Error interno", 500);
    }
    const targetUser = targetUserData?.user;
    if (!targetUser) return jsonError("Usuario no existe", 404);

    if (targetUser.email_confirmed_at) {
      return jsonError(
        "El usuario ya aceptó la invitación. Usá 'Reset password vía email' " +
          "si tiene problemas con su contraseña.",
        400,
      );
    }

    const targetEmail = targetUser.email;
    if (!targetEmail) return jsonError("Usuario sin email", 400);

    // Obtener metadata del cobrador (rol, tenant, prefijo, etc.).
    const { data: tc, error: tcErr } = await admin
      .from("cobradores")
      .select("tenant_id, rol, nombre, telefono, prefijo_recibo")
      .eq("id", body.cobrador_id)
      .maybeSingle();
    if (tcErr) {
      console.error("reenviar: cobrador lookup falló", tcErr);
      return jsonError("Error interno", 500);
    }
    if (!tc) return jsonError("Cobrador no existe", 404);

    if (tc.rol === "super_admin") {
      return jsonError(
        "No se puede reenviar invitación a otro super_admin",
        400,
      );
    }

    // Admin sólo puede operar dentro de su tenant.
    if (callerEsAdmin && tc.tenant_id !== yo.tenant_id) {
      return jsonError(
        "Sólo podés reenviar invitaciones de tu propio tenant",
        403,
      );
    }

    // Snapshot de la data del cobrador antes de borrar — necesario para
    // poder reportar al super_admin si la re-creación falla después del
    // delete y debe recrearse manualmente.
    const snapshot = {
      email: targetEmail,
      tenant_id: tc.tenant_id,
      rol: tc.rol,
      nombre: tc.nombre,
      telefono: tc.telefono ?? null,
      prefijo_recibo: ["cobrador", "admin", "admin_cobranza"].includes(tc.rol)
        ? (tc.prefijo_recibo ?? null)
        : null,
    };

    // Borrar el user (cascadea cobradores). Para pending invites esto es
    // seguro porque no hay datos operativos asociados.
    const { error: delErr } = await admin.auth.admin.deleteUser(
      body.cobrador_id,
    );
    if (delErr) {
      // status undefined cuando no hay error real; los 404 (race con otra
      // tab que ya borró) los tratamos como already-done.
      const status = (delErr as { status?: number }).status;
      if (status === 404) {
        return jsonError(
          "Otro super_admin ya reenvió esta invitación (refresca la lista)",
          409,
        );
      }
      console.error("reenviar: deleteUser falló", delErr);
      return jsonError("Error eliminando el usuario previo", 500);
    }

    // Re-crear el user con la misma metadata, mismo email. Dos paths:
    //   - enviarEmail=true → inviteUserByEmail (Supabase manda email
    //     con magic-link al user).
    //   - enviarEmail=false → createUser con password aleatoria +
    //     email_confirm=true (no manda nada; devolvemos la password
    //     en nueva_password para que el caller la comparta por otro
    //     canal). Mismo patrón que crear-tenant.
    //
    // ATENCIÓN: si la re-creación falla, el user quedó borrado sin
    // reemplazo. Logueamos el snapshot loud para recovery manual.
    const enviarEmail = body.enviar_email !== false;
    const metadata = {
      tenant_id: snapshot.tenant_id,
      rol: snapshot.rol,
      nombre: snapshot.nombre,
      telefono: snapshot.telefono,
      prefijo_recibo: snapshot.prefijo_recibo,
    };

    let invErr: { message: string } | null = null;
    let newUserId: string | null = null;
    let nuevaPassword: string | null = null;

    if (enviarEmail) {
      const { data: invite, error } = await admin.auth.admin
        .inviteUserByEmail(targetEmail, {
          data: metadata,
          redirectTo: body.redirect_to,
        });
      if (error) {
        invErr = error;
      } else if (!invite.user) {
        invErr = { message: "invite sin user" };
      } else {
        newUserId = invite.user.id;
      }
    } else {
      const generated = generarPasswordSegura();
      const { data: created, error } = await admin.auth.admin.createUser({
        email: targetEmail,
        password: generated,
        user_metadata: metadata,
        email_confirm: true,
      });
      if (error) {
        invErr = error;
      } else if (!created?.user) {
        invErr = { message: "createUser sin user" };
      } else {
        newUserId = created.user.id;
        nuevaPassword = generated;
      }
    }

    if (invErr !== null || newUserId === null) {
      const rawMsg = invErr?.message ?? "error desconocido";
      const msg = humanizeAuthError(rawMsg);
      console.error(
        "reenviar: re-creación falló DESPUÉS de delete — recovery manual " +
          "requerida con este snapshot:",
        JSON.stringify(snapshot),
        invErr,
      );
      return jsonError(
        "El usuario fue eliminado pero la re-creación falló. Recreá la " +
          "invitación manualmente desde 'Invitar' con email=" +
          `${snapshot.email} y rol=${snapshot.rol}. Detalle: ${msg}`,
        500,
      );
    }

    return new Response(
      JSON.stringify({
        ok: true,
        message: enviarEmail
          ? "Invitación reenviada por email"
          : "Credenciales generadas — compartilas con el usuario",
        new_user_id: newUserId,
        // Eco del email + password nueva sólo cuando enviar_email=false.
        // Para el flow email queda null (no exponer en logs ni en
        // history del browser).
        email: targetEmail,
        nueva_password: nuevaPassword,
      }),
      {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 200,
      },
    );
  } catch (e) {
    // No echar el error crudo al cliente: si el throw ocurrió tras
    // generar la password aleatoria (modo no-email), ésta podría
    // aparecer en el stack trace según cómo Deno formatee la
    // excepción. Loggeamos en server y devolvemos mensaje genérico.
    //
    // Importante: scrub del Error completo a solo e.message — la
    // password generada está en scope al momento del throw. Si el SDK
    // alguna vez incluyera el request body en el Error (vía `cause`),
    // `e` completo podría contener la password — los logs del
    // Dashboard son consultables por cualquier colaborador del
    // proyecto. Mismo patrón que invitar-cobrador y crear-tenant.
    const safeMessage = e instanceof Error ? e.message : String(e);
    console.error("reenviar-invitacion: unhandled error", safeMessage);
    return jsonError("Error interno — revisá los logs de la función", 500);
  } finally {
    // Soltar el lock SIEMPRE (éxito, error o throw). Best-effort: si falla, el
    // TTL de 30s lo limpia en el próximo reenvío.
    if (releaseLock) {
      try {
        await releaseLock();
      } catch (_) {
        // no-op
      }
    }
  }
});
