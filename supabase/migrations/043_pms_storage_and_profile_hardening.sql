-- ============================================================
-- 043_pms_storage_and_profile_hardening
--
-- Migración PROPIA del deploy PMS (rama `pms`), no del upstream. Cierra dos huecos que la
-- revisión del 2026-09-17 encontró en el set 001-042 y que se confirmaron POR EFECTO contra la
-- base real, no leyendo el SQL. Es idempotente, como todo el set.
--
-- ⚠ Si el upstream publica su propia 043, los dos archivos conviven: son nombres distintos y
-- ninguno de los dos depende del otro.
--
-- ------------------------------------------------------------
-- (1) El bucket `chat-media` era ENUMERABLE con la anon key
-- ------------------------------------------------------------
-- La 023 crea `chat-media` con `public = TRUE` —deliberado: Meta tiene que bajar la URL del
-- media SALIENTE sin autenticarse— y le pone esta policy de lectura:
--
--     CREATE POLICY "Chat media is publicly readable"
--       ON storage.objects FOR SELECT USING (bucket_id = 'chat-media');
--
-- Sin cláusula TO, o sea TO PUBLIC: alcanza a `anon`. Y sus hermanas de INSERT/UPDATE/DELETE
-- sí filtran por membresía de cuenta. Escrituras con scope, lectura abierta.
--
-- 🔴 MEDIDO CON CONTROL POSITIVO el 2026-09-17, que es lo único que lo prueba: se sembró un
-- objeto `cuenta-ajena/conversacion-123/foto-del-cliente.jpg` en `chat-media` y después, con
-- `SET ROLE anon`, se lo listó. Resultado: **anon ve 1 objeto y lee su ruta completa**, y un
-- usuario autenticado de OTRA cuenta también. Todo dentro de una transacción revertida.
-- ⚠ La primera versión de esa prueba devolvió 0 y parecía que no había hueco: la tabla estaba
-- vacía. Un cero sobre una tabla vacía no prueba nada — de ahí el control positivo.
--
-- Por qué importa acá: la 039 espeja a ESE MISMO bucket todo el media ENTRANTE —lo que el
-- cliente manda por WhatsApp: fotos, PDFs, audios— con `mirror_inbound_media DEFAULT TRUE`.
-- Meta nunca necesita bajar eso. Y las rutas son `account-<uuid>/inbound/<stamp>-<archivo>`,
-- así que el listado además filtra los UUID de cuenta.
--
-- 🔴 DOS COSAS QUE NO SON EL ARREGLO, y conviene saberlo antes de intentarlas:
--   · Poner el bucket en `public = FALSE` **se revierte solo**: 023 y 039 insertan con
--     `ON CONFLICT (id) DO UPDATE SET public = EXCLUDED.public`, así que la próxima corrida de
--     migraciones lo devuelve a TRUE. Y además rompería el envío saliente, que necesita la URL
--     pública (`SendMediaMessageArgs.link`).
--   · Borrar esta policy **no impide la descarga directa**: con `public = TRUE`, la ruta
--     `/storage/v1/object/public/...` no consulta RLS. Lo que esto mata es la ENUMERACIÓN, que
--     es lo que convierte «hay que adivinar una ruta» en «acá está la lista».
--
-- ⚠ LO QUE ESTO NO CIERRA, y queda anotado como pendiente real: quien conozca la ruta exacta
-- de un adjunto entrante puede bajarlo sin credenciales. El cierre completo es mandar lo
-- entrante a un bucket PRIVADO y servirlo con signed URL, que es cambio de código en
-- `src/lib/whatsapp/mirror-inbound-media.ts`. Mientras tanto, el atajo sin código es
-- `UPDATE whatsapp_config SET mirror_inbound_media = FALSE`, que reabre el problema que la 039
-- vino a resolver (Meta borra el media a los ~30 días). Hay que decidirlo ANTES de conectar un
-- número real.
DROP POLICY IF EXISTS "Chat media is publicly readable" ON storage.objects;
DROP POLICY IF EXISTS "Chat media readable by account members" ON storage.objects;
CREATE POLICY "Chat media readable by account members"
  ON storage.objects FOR SELECT
  USING (
    bucket_id = 'chat-media'
    AND EXISTS (
      SELECT 1 FROM public.profiles p
      WHERE p.user_id = auth.uid()
        AND ('account-' || p.account_id::text) = (storage.foldername(storage.objects.name))[1]
    )
  );

-- ⚠ `avatars` y `flow-media` quedan como están, A PROPÓSITO y no por olvido: tienen el mismo
-- patrón de lectura abierta, pero lo que guardan son assets de la propia empresa (fotos de
-- perfil y material que el equipo carga para los flows), no material que manda un cliente.
-- `chat-media` es el único que recibe datos de terceros.

-- ------------------------------------------------------------
-- (2) `profiles_insert` dejaba elegir la cuenta y el rol
-- ------------------------------------------------------------
-- La policy de INSERT exige sólo `uid() = user_id`; no dice nada de `account_id` ni de
-- `account_role`, que son la fuente de verdad de `is_account_member()` y por lo tanto de toda
-- la barrera entre cuentas. La 034 tapó la escalada por UPDATE con el trigger
-- `enforce_profile_privilege_columns`, pero está declarado **BEFORE UPDATE** solamente
-- (verificado con `pg_get_triggerdef`): el INSERT no pasa por ahí.
--
-- ⚠ EL CAMINO NORMAL NO ES EXPLOTABLE, y decirlo importa para no inflar el hallazgo:
-- `profiles` tiene `UNIQUE (user_id)` y el perfil lo crea solo el trigger
-- `on_auth_user_created` al registrarse, así que un usuario ya tiene su fila y no puede
-- insertar una segunda; tampoco puede borrarla, porque no hay policy de DELETE y RLS lo niega.
--
-- 🔴 PERO SÍ HAY UN CAMINO: `handle_new_user` tiene un bloque EXCEPTION (medido en `prosrc`),
-- o sea que puede tragarse un error y dejar un usuario SIN perfil. Ese usuario después se
-- inserta el suyo eligiendo `account_id` y `account_role = 'owner'` de cualquier cuenta.
--
-- Se borra la policy en vez de corregirla: el alta legítima NO la necesita. `handle_new_user`
-- es SECURITY DEFINER y su dueño es `postgres` (verificado: `prosecdef = t`), así que saltea
-- RLS; y ningún código del cliente inserta en `profiles`.
DROP POLICY IF EXISTS profiles_insert ON public.profiles;

DO $$
BEGIN
  RAISE NOTICE '043_pms: enumeracion de chat-media cerrada y profiles_insert eliminada';
END $$;
