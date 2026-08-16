// Edge Function: ver-password-cobrador
//
// Permite a un admin ver la contraseña almacenada de otro usuario,
// previa re-autenticación con su propia contraseña.
//
// Callers permitidos:
//   - admin: solo usuarios de SU MISMO tenant (no super_admin, no otro admin).
//   - super_admin: cualquier usuario excepto otro super_admin.
//
// Flujo:
//   1. Verifica el JWT del caller (ya logueado).
//   2. Verifica que sea admin o super_admin.
//   3. Re-autentica al caller con signInWithPassword (la contraseña del body).
//   4. Si OK, lee password_texto del target con service_role.
//   5. Devuelve la contraseña.
//
// Si el usuario fue creado ANTES de esta feature, password_texto será null
// y la función devuelve un mensaje indicándolo.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import { corsHeaders, jsonError } from "../_shared/response.ts";

interface VerPasswordRequest {
  cobrador_id: string;
  admin_password: string;
}

const SYSTEM_TENANT = "00000000-0000-0000-0000-000000000000";

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

    // Cliente con el JWT del caller.
    const callerClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
    });

    const { data: { user } } = await callerClient.auth.getUser();
    if (!user) return jsonError("Sesión inválida", 401);

    // Verificar rol del caller.
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
        "Solo admin o super_admin puede ver contraseñas",
        403,
      );
    }

    // Validar body.
    const body: VerPasswordRequest = await req.json();
    if (!body.cobrador_id || !body.admin_password) {
      return jsonError("cobrador_id y admin_password son requeridos", 400);
    }
    if (body.cobrador_id === user.id) {
      return jsonError("No podés ver tu propia contraseña desde acá", 400);
    }

    // Re-autenticar al caller con su contraseña.
    const verifyClient = createClient(supabaseUrl, anonKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });
    const { error: signInErr } = await verifyClient.auth.signInWithPassword({
      email: user.email!,
      password: body.admin_password,
    });
    if (signInErr) {
      return jsonError("Contraseña incorrecta", 403);
    }

    // Cliente con service_role para leer password_texto.
    const admin = createClient(supabaseUrl, serviceKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });

    // Verificar target.
    const { data: target, error: tgtErr } = await admin
      .from("cobradores")
      .select("id, tenant_id, rol, password_texto")
      .eq("id", body.cobrador_id)
      .maybeSingle();

    if (tgtErr) {
      console.error("ver-password: lookup failed", tgtErr);
      return jsonError("Error interno", 500);
    }
    if (!target) return jsonError("Usuario no existe", 404);

    if (target.rol === "super_admin") {
      return jsonError("No se puede ver la contraseña de un super_admin", 403);
    }
    if (target.tenant_id === SYSTEM_TENANT) {
      return jsonError("No se puede ver la contraseña de un usuario del sistema", 403);
    }

    // Scope del admin: solo su tenant, no otro admin.
    if (callerEsAdmin) {
      if (target.tenant_id !== yo.tenant_id) {
        return jsonError("No podés ver la contraseña de un usuario de otro tenant", 403);
      }
      if (target.rol === "admin") {
        return jsonError("Un admin no puede ver la contraseña de otro admin", 403);
      }
    }

    if (!target.password_texto) {
      return new Response(
        JSON.stringify({
          ok: true,
          password: null,
          message: "No hay contraseña almacenada para este usuario. "
            + "Solo se almacena a partir de la próxima creación o reset de contraseña.",
        }),
        {
          headers: { ...corsHeaders, "Content-Type": "application/json" },
          status: 200,
        },
      );
    }

    return new Response(
      JSON.stringify({
        ok: true,
        password: target.password_texto,
        message: "Contraseña obtenida",
      }),
      {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 200,
      },
    );
  } catch (e) {
    console.error("ver-password: unhandled error", e);
    return jsonError("Error interno", 500);
  }
});
