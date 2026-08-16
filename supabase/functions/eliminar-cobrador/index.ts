// Edge Function: eliminar-cobrador
//
// Elimina permanentemente a un miembro de un tenant. Pensado para limpiar
// usuarios sin operación (pending invites viejos, admins de prueba que
// nunca trabajaron, etc.). Para usuarios con historial real, la opción
// correcta es 'Desactivar' (preserva pagos / recibos / auditoría).
//
// Comportamiento:
//   - Cuenta el historial operativo del usuario (pagos / recibos /
//     cargos / clientes activos).
//   - Si hay CUALQUIER fila > 0, bloquea con un mensaje claro sugiriendo
//     desactivar en vez. Esto evita FK violations + audit huérfano.
//   - Si todo está limpio, captura el snapshot mínimo para audit y
//     llama a auth.admin.deleteUser (cascadea cobradores).
//
// Guards:
//   - Sólo super_admin.
//   - No se borra a sí mismo.
//   - No se borra a otro super_admin.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import { corsHeaders, jsonError } from "../_shared/response.ts";

interface EliminarRequest {
  cobrador_id: string;
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
      return jsonError("Sólo super_admin puede eliminar usuarios", 403);
    }

    const body: EliminarRequest = await req.json();
    if (!body.cobrador_id) {
      return jsonError("cobrador_id requerido", 400);
    }
    if (body.cobrador_id === user.id) {
      return jsonError("No podés eliminarte a vos mismo", 400);
    }

    const admin = createClient(supabaseUrl, serviceKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });

    // Snapshot para audit + verificar que no es super_admin.
    const { data: tc, error: tcErr } = await admin
      .from("cobradores")
      .select("tenant_id, rol, nombre")
      .eq("id", body.cobrador_id)
      .maybeSingle();
    if (tcErr) {
      console.error("eliminar: cobrador lookup falló", tcErr);
      return jsonError("Error interno", 500);
    }
    if (!tc) return jsonError("Cobrador no existe", 404);

    if (tc.rol === "super_admin") {
      return jsonError("No se puede eliminar a otro super_admin", 400);
    }

    // Contar operaciones — si hay historial operativo, bloqueamos y
    // sugerimos desactivar en vez. Evita FK violations + audit huérfano.
    // Pagos/recibos cuentan incluso anulados porque siguen siendo
    // historial relevante.
    //
    // Además de cobrador_id (creador), contamos las columnas de
    // atribución (anulado_por, aplicado_por) porque son FK ON DELETE
    // SET NULL — sin esta protección, eliminar al super_admin que anuló
    // 5000 pagos borraría la atribución de quién los anuló.
    const [
      pagosRes,
      recibosRes,
      cargosRes,
      clientesRes,
      pagosAnuladosPor,
      recibosAnuladosPor,
      cargosAplicadosPor,
    ] = await Promise.all([
      admin.from("pagos").select("id", { count: "exact", head: true })
        .eq("cobrador_id", body.cobrador_id),
      admin.from("recibos").select("id", { count: "exact", head: true })
        .eq("cobrador_id", body.cobrador_id),
      admin.from("cargos_extra").select("id", { count: "exact", head: true })
        .eq("cobrador_id", body.cobrador_id),
      admin.from("clientes").select("id", { count: "exact", head: true })
        .eq("cobrador_id", body.cobrador_id),
      admin.from("pagos").select("id", { count: "exact", head: true })
        .eq("anulado_por", body.cobrador_id),
      admin.from("recibos").select("id", { count: "exact", head: true })
        .eq("anulado_por", body.cobrador_id),
      admin.from("cargos_extra").select("id", { count: "exact", head: true })
        .eq("aplicado_por", body.cobrador_id),
    ]);

    // Si alguna count query falla, abortamos por defensiveness — no
    // queremos eliminar pensando que el count era 0 cuando en realidad
    // hubo un error.
    const allRes = [
      pagosRes,
      recibosRes,
      cargosRes,
      clientesRes,
      pagosAnuladosPor,
      recibosAnuladosPor,
      cargosAplicadosPor,
    ];
    for (const r of allRes) {
      if (r.error) {
        console.error("eliminar: count query falló", r.error);
        return jsonError("Error contando historial del usuario", 500);
      }
    }

    const pagos = pagosRes.count ?? 0;
    const recibos = recibosRes.count ?? 0;
    const cargos = cargosRes.count ?? 0;
    const clientes = clientesRes.count ?? 0;
    const pagosAnul = pagosAnuladosPor.count ?? 0;
    const recibosAnul = recibosAnuladosPor.count ?? 0;
    const cargosApl = cargosAplicadosPor.count ?? 0;

    // Tablas agregadas DESPUÉS del guard original (visitas, fotos, tickets,
    // inventario): el delete perdía atribución en silencio (FK SET NULL) o
    // reventaba con FK violation (visitas.cobrador_id NOT NULL). Conteo
    // TOLERANTE a tabla inexistente (migraciones 0099-0107 sin correr):
    // PostgREST moderno devuelve PGRST205 ("table not in schema cache");
    // versiones viejas / cache stale devuelven 42P01. Ambos cuentan como 0
    // para no bloquear el delete en una DB sin esos módulos; cualquier OTRO
    // error sí aborta (defensiveness del guard base).
    const countOpcional = async (
      tabla: string,
      columna: string,
    ): Promise<number | null> => {
      const r = await admin.from(tabla)
        .select("id", { count: "exact", head: true })
        .eq(columna, body.cobrador_id);
      if (r.error) {
        if (r.error.code === "42P01" || r.error.code === "PGRST205") {
          return 0; // tabla aún no deployada
        }
        console.error(`eliminar: count ${tabla}.${columna} falló`, r.error);
        return null; // error real → abortar
      }
      return r.count ?? 0;
    };

    const extras = await Promise.all([
      countOpcional("visitas", "cobrador_id"),
      countOpcional("fotos_cliente", "created_by"),
      // fotos_cliente.cobrador_id / contratos.cobrador_id / cuotas.cobrador_id
      // son FK SIN ON DELETE (NO ACTION): si referencian al target y no se
      // cuentan, el deleteUser revienta con FK violation (500 feo) DESPUÉS
      // de haber escrito la fila de audit. Contarlas cierra ese hueco.
      countOpcional("fotos_cliente", "cobrador_id"),
      countOpcional("contratos", "cobrador_id"),
      countOpcional("cuotas", "cobrador_id"),
      countOpcional("tickets", "asignado_a"),
      countOpcional("tickets", "creado_por"),
      countOpcional("ticket_eventos", "hecho_por"),
      countOpcional("ticket_adjuntos", "subido_por"),
      countOpcional("ticket_materiales", "hecho_por"),
      countOpcional("inv_movimientos", "hecho_por"),
      countOpcional("inv_ubicaciones", "cobrador_id"),
    ]);
    if (extras.some((n) => n === null)) {
      return jsonError("Error contando historial del usuario", 500);
    }
    const [
      visitas,
      fotosCreadas,
      fotosCobrador,
      contratos,
      cuotas,
      ticketsAsig,
      ticketsCre,
      eventos,
      adjuntos,
      materiales,
      movimientos,
      ubicaciones,
    ] = extras as number[];
    const fotos = fotosCreadas + fotosCobrador;
    const totalExtras = visitas + fotos + contratos + cuotas +
      ticketsAsig + ticketsCre + eventos + adjuntos + materiales +
      movimientos + ubicaciones;

    const total = pagos + recibos + cargos + clientes +
      pagosAnul + recibosAnul + cargosApl + totalExtras;
    if (total > 0) {
      const partesExtras = [
        visitas > 0 ? `${visitas} visitas` : null,
        fotos > 0 ? `${fotos} fotos` : null,
        contratos > 0 ? `${contratos} contratos asignados` : null,
        cuotas > 0 ? `${cuotas} cuotas asignadas` : null,
        (ticketsAsig + ticketsCre) > 0
          ? `${ticketsAsig + ticketsCre} tickets`
          : null,
        eventos > 0 ? `${eventos} eventos de ticket` : null,
        adjuntos > 0 ? `${adjuntos} adjuntos de ticket` : null,
        materiales > 0 ? `${materiales} consumos de material` : null,
        movimientos > 0 ? `${movimientos} movimientos de inventario` : null,
        ubicaciones > 0 ? `${ubicaciones} ubicaciones de custodia` : null,
      ].filter((s) => s !== null);
      const sufijo = partesExtras.length > 0
        ? `, ${partesExtras.join(", ")}`
        : "";
      return jsonError(
        "No se puede eliminar: tiene historial operativo " +
          `(${pagos} pagos creados, ${recibos} recibos, ${cargos} cargos, ` +
          `${clientes} clientes asignados, ${pagosAnul} pagos anulados ` +
          `por él, ${recibosAnul} recibos anulados por él, ${cargosApl} ` +
          `cargos aplicados por él${sufijo}). Usá 'Desactivar' en su lugar ` +
          "para preservar el historial.",
        409,
      );
    }

    // Delete (cascadea la fila de cobradores por la FK).
    const { error: delErr } = await admin.auth.admin.deleteUser(
      body.cobrador_id,
    );
    if (delErr) {
      console.error("eliminar: deleteUser falló", delErr);
      return jsonError(
        `No se pudo eliminar el usuario: ${delErr.message}`,
        500,
      );
    }

    // op_log de baja (fix F0): deja constancia de la eliminación del miembro.
    // Lo emite el edge (service role) porque la baja es server-side y la hace el
    // super_admin (actor = System Admin, actor_id NULL — misma convención que
    // OpLog.actorDeUsuario). Best-effort: si falla, no revierte el delete.
    try {
      await admin.from("op_log").insert({
        tenant_id: tc.tenant_id,
        op_id: crypto.randomUUID(),
        tipo_op: "baja_entidad",
        entidad: "cobradores",
        entidad_id: body.cobrador_id,
        actor_id: null,
        actor_label: "System Admin",
        accion: "delete",
        diff: JSON.stringify({
          campos: [
            { campo: "nombre", antes: tc.nombre, despues: null },
            { campo: "rol", antes: tc.rol, despues: null },
          ],
        }),
        ocurrido_en: new Date().toISOString(),
      });
    } catch (e) {
      console.error("eliminar: op_log baja falló (no crítico)", e);
    }

    return new Response(
      JSON.stringify({
        ok: true,
        message: "Usuario eliminado",
      }),
      {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 200,
      },
    );
  } catch (e) {
    console.error("eliminar-cobrador: unhandled", e);
    return jsonError("Error interno", 500);
  }
});
