# 3 — Instalar / actualizar en Android

El APK se firma con el **keystore RELEASE dedicado** (`android/key.properties` +
`sitecsa-release.jks`, gitignored — viven solo en el worktree principal de la PC
de build; `build-release.ps1` **ABORTA** si faltan, así no se produce un APK
debug-signed que las apps instaladas rechazarían). Update **in-place**: instalar
sobre la versión vieja mantiene los datos, mientras el `applicationId` y el
keystore no cambien.

---

## Instalar

1. En el teléfono, descargá el APK branded del ISP desde la página del último
   release `https://github.com/rubenmaltez/sitecsa-updates/releases/latest`
   (`Telecable-Mairena-CRM-vX.Y.Z.apk` para Mairena, `Telenet-CRM-vX.Y.Z.apk`
   para Telenet) — o pasá ese mismo `.apk` del Escritorio / `Releases\vX.Y.Z\`
   por WhatsApp / USB.
2. Abrí el APK desde la barra de notificaciones o el explorador de archivos.
3. La primera vez, Android pide permitir **"Instalar apps desconocidas"** para
   el navegador/explorador con el que lo abrís → activalo → volvé atrás →
   **Instalar**.
4. Si ya tenías una versión, tocá **Actualizar** (no pide desinstalar).

---

## Verificar

Abrí la app → en el **login** (al pie) y en **Perfil** (cobrador, al pie) debe
decir `CRM vX.Y.Z`.

## Si dice "app no instalada" / conflicto de firma

Con el keystore release dedicado esto ya NO pasa entre releases oficiales: la
firma es siempre la misma (la del `sitecsa-release.jks`), se buildee desde la PC
que sea. Hoy solo aparece si alguien instala un APK buildeado **a mano** sin el
keystore (queda debug-signed → firma distinta a la instalada). Solución:
desinstalá la app vieja e instalá el **APK oficial del release**. La data está
en el backend, no se pierde (vuelve a sincronizar al loguearte).
