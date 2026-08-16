// Edge Function: crear-tenant
//
// Crea un tenant completo en un solo click desde el panel super_admin:
//   1. Inserta el row en `tenants` (el trigger habilita los módulos base).
//   2. Habilita módulos no-base extra vía set_tenant_modulo RPC.
//   3. Crea al admin con metadata. Dos modos según enviar_email:
//      - true  → inviteUserByEmail (manda email automático con link).
//      - false → createUser con password aleatoria + email_confirm=true
//                (no manda email; devuelve admin_password para que el
//                super_admin lo comparta por otro canal). Workaround
//                para SMTP en sandbox o destinatarios sin email
//                automatizado. Mismo patrón que forzar-password-cobrador.
//
// Si algo falla tras crear el tenant, hace rollback completo:
//   - Borra el user de auth.users (cascade limpia cobradores).
//   - Borra el tenant (cascade limpia tenant_modulos / settings).
// Si el rollback también falla, devuelve `orphan_tenant_id` para que
// el super_admin lo limpie manualmente.
//
// Despliegue:
//   supabase functions deploy crear-tenant
//   (o pegando este archivo en Supabase Dashboard → Edge Functions)
//
// Variables esperadas (configuradas automáticamente por Supabase):
//   SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY
//
// Body esperado (JSON):
//   {
//     "tenant_nombre": "ISP Las Lomas",
//     "admin_email": "marcos@laslomas.ni",
//     "admin_nombre": "Marcos Pineda",
//     "admin_telefono": "+50588881234",      // opcional
//     "modulos_extra": ["inventario"],        // opcional, sólo no-base
//     "redirect_to": "https://app.../?flow=invite",  // opcional
//     "enviar_email": true                    // opcional, default true
//   }
//
// Respuesta éxito:
//   { ok: true, tenant_id, admin_user_id, admin_password?, message }
//   admin_password sólo viene cuando enviar_email=false — es la
//   contraseña generada para el admin, que el super_admin tiene que
//   compartir por canal seguro (no queda guardada en ningún lado).

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import { corsHeaders, jsonError } from "../_shared/response.ts";
import { humanizeAuthError } from "../_shared/auth_errors.ts";
import { generarPasswordSegura } from "../_shared/passwords.ts";

interface CrearTenantRequest {
  tenant_nombre: string;
  admin_email: string;
  admin_nombre: string;
  admin_telefono?: string;
  modulos_extra?: string[];
  redirect_to?: string;
  // Si false, no manda email — crea al user con una password aleatoria
  // (email_confirm=true para skipear el email de verificación) y la
  // devuelve en admin_password. El super_admin la comparte por otro
  // canal y el admin se loguea normal con email+password. Workaround
  // del bug PKCE+cross-browser para links generados manualmente.
  enviar_email?: boolean;
  // Password manual (sólo path no-email): si el super_admin la provee,
  // se usa esa en vez de generar una. Min 8 chars (validado inline).
  // Cuando es manual NO la eco-devolvemos en `admin_password` (el caller
  // ya la conoce — no exponemos un secreto provisto por el caller).
  password?: string;
}

const SYSTEM_TENANT = "00000000-0000-0000-0000-000000000000";

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  // Variables que sobreviven al outer catch para poder rollbackear si
  // una excepción no anticipada ocurre tras la creación parcial. Sin
  // esto, una excepción entre createUser éxito y `new Response()`
  // dejaba orphan tenant + auth.users.
  let tenantId: string | null = null;
  let userIdParcial: string | null = null;
  // admin client se setea apenas leemos las env vars — necesario para
  // el rollback en el outer catch.
  let adminForRollback: ReturnType<typeof createClient> | null = null;
  // Flag que marcamos true cuando llegamos al final del flow happy.
  // Si está false en el catch, hay state parcial para limpiar.
  let success = false;

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return jsonError("Authorization header faltante", 401);
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

    // callerClient = JWT del super_admin → atraviesa RLS y deja el audit
    // trail correcto (habilitado_por = super_admin en tenant_modulos).
    const callerClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
    });

    const { data: { user } } = await callerClient.auth.getUser();
    if (!user) return jsonError("Sesión inválida", 401);

    // Verificar caller es super_admin.
    const { data: yo, error: yoErr } = await callerClient
      .from("cobradores")
      .select("rol")
      .eq("id", user.id)
      .single();
    if (yoErr || !yo) {
      return jsonError("No estás en la tabla cobradores", 403);
    }
    if (yo.rol !== "super_admin") {
      return jsonError("Sólo super_admin puede crear tenants", 403);
    }

    // Validar body.
    const body: CrearTenantRequest = await req.json();
    const nombre = (body.tenant_nombre ?? "").trim();
    const email = (body.admin_email ?? "").trim().toLowerCase();
    const adminNombre = (body.admin_nombre ?? "").trim();
    const adminTelefono = body.admin_telefono?.trim() || null;
    const modulosExtra = Array.isArray(body.modulos_extra)
      ? body.modulos_extra
      : [];
    // Default true: el caller tiene que pedir explícitamente "no email"
    // para activar el flow de createUser+password. Falsey check tolera
    // null/undefined además de false.
    const enviarEmail = body.enviar_email !== false;

    if (!nombre) return jsonError("tenant_nombre es requerido", 400);
    if (nombre.length > 120) {
      return jsonError("tenant_nombre demasiado largo (max 120)", 400);
    }
    // 'System' es el nombre del tenant interno (UUID 00000000-...) que
    // aloja a los super_admin. Permitir crear otro "System" confundiría
    // la lista — bloqueamos case-insensitive.
    if (nombre.toLowerCase() === "system") {
      return jsonError(
        '"System" es un nombre reservado, usá otro',
        400,
      );
    }
    if (!email || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) {
      return jsonError("admin_email inválido", 400);
    }
    if (!adminNombre) return jsonError("admin_nombre es requerido", 400);
    // Rechazamos chars de control C0/C1 — Postgres text/jsonb los
    // tratan inconsistente y dan errores opacos en lugar de input
    // validation clara. adminTelefono puede ser null.
    const CONTROL = /[\x00-\x1F\x7F-\x9F]/;
    if (
      CONTROL.test(nombre) ||
      CONTROL.test(email) ||
      CONTROL.test(adminNombre) ||
      (adminTelefono !== null && CONTROL.test(adminTelefono))
    ) {
      return jsonError(
        "Los campos no pueden contener caracteres de control",
        400,
      );
    }
    if (adminNombre.length > 120) {
      return jsonError("admin_nombre demasiado largo (max 120)", 400);
    }
    if (adminTelefono !== null && adminTelefono.length > 32) {
      return jsonError("admin_telefono demasiado largo (max 32)", 400);
    }
    // Password manual (sólo aplica al path no-email): validamos min 8
    // ACÁ ARRIBA, antes de crear el tenant, para no tener que
    // rollbackear por una password corta. El min va inline (no en el
    // _shared) para no re-bundlear. En el path email se ignora.
    if (
      !enviarEmail &&
      typeof body.password === "string" &&
      body.password.length > 0 &&
      body.password.length < 8
    ) {
      return jsonError(
        "La contraseña debe tener al menos 8 caracteres",
        400,
      );
    }

    // service_role: sólo para el invite (auth.admin) y rollback. Las
    // operaciones de DB van vía callerClient para que la RLS valide.
    // Lo asignamos también a adminForRollback para que el outer catch
    // pueda usarlo si tiene que limpiar state parcial.
    const admin = createClient(supabaseUrl, serviceKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });
    adminForRollback = admin;

    // Pre-flight: validar que los módulos extra existen y no son base.
    // (Base se habilita auto por trigger; pasarlos en "extra" sería
    // un no-op confuso.) También evita un rollback caro si alguien
    // tipea mal el código del módulo.
    if (modulosExtra.length > 0) {
      const { data: modRows, error: modErr } = await admin
        .from("modulos")
        .select("codigo, es_base")
        .in("codigo", modulosExtra);
      if (modErr) {
        return jsonError(`Error validando módulos: ${modErr.message}`, 500);
      }
      const encontrados = new Set((modRows ?? []).map((m) => m.codigo));
      const faltantes = modulosExtra.filter((m) => !encontrados.has(m));
      if (faltantes.length > 0) {
        return jsonError(
          `Módulos inexistentes: ${faltantes.join(", ")}`,
          400,
        );
      }
      const baseEnExtra = (modRows ?? [])
        .filter((m) => m.es_base)
        .map((m) => m.codigo);
      if (baseEnExtra.length > 0) {
        return jsonError(
          `Módulos base no van en modulos_extra (ya se habilitan ` +
            `automáticamente): ${baseEnExtra.join(", ")}`,
          400,
        );
      }
    }

    // Pre-flight: chequear que el email no exista en auth.users.
    // Usa RPC SECURITY DEFINER que consulta auth.users directamente.
    // Hacemos el check antes de cualquier creación para devolver el
    // error en español sin disparar el rollback de tenant.
    const { data: emailExists, error: lookupErr } = await admin.rpc(
      "check_email_exists_in_auth",
      { p_email: email },
    );
    if (lookupErr) {
      return jsonError(
        `No pude verificar el email: ${lookupErr.message}`,
        500,
      );
    }
    if (emailExists) {
      return jsonError(
        "Ya existe un usuario con ese email — usá otro o, " +
          "si querés moverlo de tenant, contactá soporte.",
        400,
      );
    }

    // 1. Crear el tenant. RLS `super_admin_all` lo permite vía callerClient.
    //    El trigger `trg_tenants_habilitar_modulos_base` habilita cobranza.
    const { data: nuevoTenant, error: tErr } = await callerClient
      .from("tenants")
      .insert({ nombre })
      .select("id")
      .single();
    if (tErr || !nuevoTenant) {
      return jsonError(`Error creando tenant: ${tErr?.message}`, 500);
    }
    // Asignamos al outer scope para que el catch pueda rollbackear si
    // una excepción no anticipada ocurre más adelante.
    tenantId = nuevoTenant.id as string;

    // Guard contra accidente cósmico: el insert NO debería retornar el
    // System tenant, pero si por algún motivo se devolviera, abortamos.
    if (tenantId === SYSTEM_TENANT) {
      return jsonError("Conflicto: el tenant creado es System", 500);
    }

    // 2. Habilitar módulos extra. Usamos la RPC para mantener el audit
    //    trail (`habilitado_por = super_admin`). Si uno falla, rollback.
    for (const modulo of modulosExtra) {
      const { error: setErr } = await callerClient.rpc("set_tenant_modulo", {
        p_tenant_id: tenantId,
        p_modulo: modulo,
        p_habilitado: true,
      });
      if (setErr) {
        await rollbackTenant(admin, tenantId);
        return jsonError(
          `Error habilitando módulo ${modulo}: ${setErr.message}`,
          500,
        );
      }
    }

    // 3. Crear el user con metadata. Dos paths:
    //    a) enviarEmail=true → inviteUserByEmail (manda email con
    //       link de set-password).
    //    b) enviarEmail=false → createUser con password aleatoria +
    //       email_confirm=true (no manda nada). El super_admin recibe
    //       la password en la respuesta y la pasa por otro canal —
    //       el admin se loguea normal por /login. Evita el problema
    //       PKCE+cross-browser de los magic-links generados a mano.
    //    En ambos casos, el trigger handle_new_user inserta la fila
    //    en cobradores con rol=admin + tenant_id correcto al crearse
    //    el row en auth.users.
    const metadata = {
      tenant_id: tenantId,
      rol: "admin",
      nombre: adminNombre,
      telefono: adminTelefono,
    };

    let adminUserId: string | null = null;
    // userIdParcial está declarado en el outer scope (línea ~81) para
    // que el outer catch pueda hacer cleanup si una excepción
    // inesperada ocurre tras la creación del user. Acá lo asignamos.
    let adminPassword: string | null = null;
    let invErrMsg: string | null = null;

    if (enviarEmail) {
      const { data: invite, error: invErr } = await admin.auth.admin
        .inviteUserByEmail(email, {
          data: metadata,
          redirectTo: body.redirect_to,
        });
      if (invErr || !invite?.user) {
        invErrMsg = invErr?.message ?? "No se creó el usuario";
        userIdParcial = invite?.user?.id ?? null;
      } else {
        adminUserId = invite.user.id;
      }
    } else {
      // La password puede venir del super_admin (manual) o la genera el
      // server. El min-8 ya se validó arriba (antes de crear el tenant)
      // para no tener que rollbackear por una password corta. Si la
      // genera el server, no la conoce nadie más — la response es la
      // única oportunidad del super_admin de verla.
      const manual = typeof body.password === "string" &&
        body.password.length > 0;
      const generated = manual ? body.password! : generarPasswordSegura();
      const { data: created, error: createErr } = await admin.auth.admin
        .createUser({
          email,
          password: generated,
          user_metadata: metadata,
          // email_confirm=true skipea el email de verificación de
          // Supabase. El user queda confirmado y puede loguearse ya
          // mismo con la password generada. Modelo de confianza:
          // el super_admin verifica la propiedad del email
          // out-of-band (llamada/whatsapp al ISP); misma postura que
          // forzar-password-cobrador para users existentes.
          email_confirm: true,
        });
      userIdParcial = created?.user?.id ?? null;
      if (createErr || !created?.user) {
        invErrMsg = createErr?.message ?? "No se creó el usuario";
      } else {
        adminUserId = created.user.id;
        // Si es manual NO eco-devolvemos la password: el caller ya la
        // conoce, no exponemos un secreto provisto por el caller. Sólo
        // devolvemos la generada por el server.
        adminPassword = manual ? null : generated;
      }
    }

    if (invErrMsg !== null || adminUserId === null) {
      // Rollback: borrar primero el user de auth.users (cascade limpia
      // cobradores via cobradores.id → auth.users(id) ON DELETE
      // CASCADE), después borrar el tenant.
      //
      // Si deleteUser falla (raro: blip de red entre createUser y
      // este punto), la FK cobradores.tenant_id va a bloquear el
      // delete del tenant — terminamos con auth.users huérfano
      // apuntando a un tenant inexistente. Loggeamos pero no
      // abortamos: el rollbackTenant siguiente devolverá su propio
      // error si la FK se queja, y el orphan_tenant_id en la
      // respuesta le dice al super_admin que hay que limpiar.
      if (userIdParcial !== null) {
        const { error: delErr } = await admin.auth.admin
          .deleteUser(userIdParcial);
        if (delErr) {
          console.error(
            `crear-tenant deleteUser falló en rollback (user=${userIdParcial}, ` +
              `tenant=${tenantId}): ${delErr.message}`,
          );
        }
      }
      const rollbackOk = await rollbackTenant(admin, tenantId);
      // Capturamos el id ANTES de nullear las vars — el rollback fallido
      // necesita reportar `orphan_tenant_id` al super_admin para limpieza
      // manual, y si lo leemos del scope outer (que vamos a nullear),
      // termina como `null`. Bug encontrado en QA audit pre-merge.
      const orphanTenantId = tenantId;
      // Nulleamos las vars del outer scope para que el outer catch
      // no intente un segundo rollback sobre los mismos ids (no
      // afecta correctness — los delete son idempotentes — pero
      // genera noise en los logs).
      userIdParcial = null;
      tenantId = null;
      const msg = humanizeAuthError(invErrMsg ?? "Error desconocido");
      if (!rollbackOk) {
        // Cleanup falló — devolvemos el orphan id para limpieza manual.
        return new Response(
          JSON.stringify({
            ok: false,
            error: `Invite falló (${msg}) y el rollback también. ` +
              `Borrá manualmente el tenant ${orphanTenantId}.`,
            orphan_tenant_id: orphanTenantId,
          }),
          {
            headers: { ...corsHeaders, "Content-Type": "application/json" },
            status: 500,
          },
        );
      }
      return jsonError(`Invite falló: ${msg}`, 400);
    }

    // Marcamos success ANTES de armar la response, así el outer catch
    // sabe que llegamos al estado limpio (no necesita rollback).
    success = true;
    return new Response(
      JSON.stringify({
        ok: true,
        tenant_id: tenantId,
        admin_user_id: adminUserId,
        // Eco del email — el cliente lo necesita para mostrar el
        // bloque "email + password" sin tener que re-leerlo del form
        // (que ya pudo ser disposed).
        admin_email: email,
        // admin_password sólo viene cuando enviar_email=false. Es la
        // única oportunidad del super_admin de verla — no queda
        // guardada en ningún lado, y si la pierde tiene que ir a
        // 'Forzar contraseña' desde el detalle del miembro.
        admin_password: adminPassword,
        message: enviarEmail
          ? "Tenant creado e invitación enviada por email"
          : "Tenant creado — compartí las credenciales con el admin",
      }),
      {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 200,
      },
    );
  } catch (e) {
    // No echar el error crudo al cliente: si el throw ocurrió tras
    // generar la password aleatoria, ésta podría aparecer en el stack
    // trace según cómo Deno formatee la excepción (depende de
    // --inspect / --log-level). Loggeamos en server para diagnosticar
    // y devolvemos un mensaje genérico al cliente.
    //
    // Importante: scrub del Error completo a solo e.message — `generated`
    // (password) está en scope al momento del throw. Si el SDK alguna
    // vez incluyera el request body en el Error (vía `cause` o similar),
    // `e` completo podría contener la password — los logs del Dashboard
    // son consultables por cualquier colaborador del proyecto. Mismo
    // patrón que invitar-cobrador. Defense in depth.
    const safeMessage = e instanceof Error ? e.message : String(e);
    console.error("crear-tenant unhandled error:", safeMessage);

    // Cleanup de state parcial: si llegamos a crear user/tenant pero
    // una excepción rompió el flow antes del response, hay que limpiar
    // para no dejar orphans. success=true significa que llegamos al
    // happy path; si está false acá hay que rollbackear.
    //
    // Cada delete está envuelto en su propio try/catch: si el SDK
    // tira excepción síncrona (UUID malformado, etc.), no queremos
    // que rebrote del outer catch y produzca un 500 sin nuestro
    // mensaje genérico — preferimos loggear el problema y continuar
    // con la response genérica.
    if (!success && adminForRollback !== null) {
      if (userIdParcial !== null) {
        try {
          const { error: delUserErr } = await adminForRollback.auth.admin
            .deleteUser(userIdParcial);
          if (delUserErr) {
            console.error(
              `crear-tenant rollback deleteUser falló (user=${userIdParcial}): ${delUserErr.message}`,
            );
          }
        } catch (deleteUserThrow) {
          // Scrub: misma justificación que el outer catch — `generated`
          // (la password) sigue viva en este scope. Si el SDK alguna vez
          // incluyera el request body en el Error, el message-only impide
          // que aparezca en los logs.
          const msg = deleteUserThrow instanceof Error
            ? deleteUserThrow.message
            : String(deleteUserThrow);
          console.error(
            `crear-tenant rollback deleteUser threw (user=${userIdParcial}):`,
            msg,
          );
        }
      }
      if (tenantId !== null) {
        try {
          const { error: delTenantErr } = await adminForRollback
            .from("tenants").delete().eq("id", tenantId);
          if (delTenantErr) {
            console.error(
              `crear-tenant rollback deleteTenant falló (tenant=${tenantId}): ${delTenantErr.message}. ORPHAN.`,
            );
          }
        } catch (deleteTenantThrow) {
          const msg = deleteTenantThrow instanceof Error
            ? deleteTenantThrow.message
            : String(deleteTenantThrow);
          console.error(
            `crear-tenant rollback deleteTenant threw (tenant=${tenantId}). ORPHAN:`,
            msg,
          );
        }
      }
    }

    return jsonError("Error interno — revisá los logs de la función", 500);
  }
});

async function rollbackTenant(
  admin: ReturnType<typeof createClient>,
  tenantId: string,
): Promise<boolean> {
  // service_role evita el "no tengo permiso" si el caller llegó a este
  // punto pero su sesión expiró entre el insert y el rollback. Cascade
  // cubre tenant_modulos / settings / etc.
  const { error } = await admin.from("tenants").delete().eq("id", tenantId);
  return !error;
}
