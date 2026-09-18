import { NextResponse, type NextRequest } from 'next/server'

import { createClient } from '@/lib/supabase/server'

/**
 * Landing point for every Supabase link that carries a one-time code.
 *
 * Today that is exactly one flow: password recovery. `/forgot-password` calls
 * `resetPasswordForEmail` with `redirectTo: <origin>/auth/callback?next=/reset-password`,
 * GoTrue mails a link to its own `/auth/v1/verify`, and once it has verified the
 * token it bounces the browser here with `?code=`. That code is useless on its
 * own: it has to be exchanged for a session, and the PKCE verifier that unlocks
 * it lives in a cookie this route can read but the mail client cannot.
 *
 * Until this file existed the mailed link pointed at a route that did not exist.
 * The mail went out, the user clicked, and Next.js answered 404 — with the
 * recovery token spent. Nothing in the app reported it, because the failure is
 * entirely on the receiving end (measured 2026-09-17: the app's only auth pages
 * were /login, /signup and /forgot-password).
 */

/**
 * `next` comes from the query string, so it is attacker-controlled and cannot be
 * fed to a redirect as-is.
 *
 * Checking `startsWith('/')` alone is NOT enough: `//evil.com` and `/\evil.com`
 * both start with a slash and both resolve to a *different host* — they are
 * protocol-relative URLs. That turns this route into an open redirect on a page
 * the user reaches straight from their inbox, which is the ideal place to land a
 * phishing page: the address bar showed our domain one hop earlier.
 */
function safeNext(raw: string | null): string {
  if (!raw || !raw.startsWith('/')) return '/dashboard'
  if (raw.startsWith('//') || raw.startsWith('/\\')) return '/dashboard'
  return raw
}

/**
 * 🔴 EL `Location` VA RELATIVO, Y NO ES UNA PREFERENCIA DE ESTILO.
 *
 * En un Route Handler, `request.nextUrl` se arma desde la direccion en la que el
 * servidor escucha —con `HOSTNAME=0.0.0.0` y `PORT=3000` eso da
 * `https://0.0.0.0:3000`— y no desde el `Host` del pedido. Un redirect
 * construido con `nextUrl.clone()` sale apuntando ahi y el navegador no puede
 * seguirlo: el reseteo de contraseña termina en ninguna parte.
 *
 * ⚠ En `src/middleware.ts` el MISMO idiom si funciona, y por eso engaña: ahi
 * `nextUrl` toma el Host real del pedido. Medido contra el deploy del
 * 2026-09-17: `/`, que redirige el middleware, emite
 * `Location: https://crm.<dominio>/dashboard`, mientras esta ruta emitia
 * `https://0.0.0.0:3000/reset-password`.
 *
 * Un `Location` relativo es valido en HTTP y lo resuelve el navegador contra la
 * URL que ya tiene: correcto detras de cualquier proxy, y sin tener que adivinar
 * el host a partir de cabeceras que se pueden falsificar.
 */
function redirigir(destino: string) {
  return new NextResponse(null, { status: 307, headers: { Location: destino } })
}

/**
 * Every failure lands on /reset-password with an `error`, instead of a bare 404
 * or a silent bounce to /login. That page has no session in this case and says
 * so — "the link expired, ask for another one" — which is the only thing the
 * person can act on. A redirect to /login would show a password box to someone
 * who is there precisely because they do not have a password.
 */
function fail(reason: string) {
  return redirigir(`/reset-password?error=${encodeURIComponent(reason)}`)
}

export async function GET(request: NextRequest) {
  const { searchParams } = request.nextUrl

  // GoTrue reports an expired or already-used link by redirecting HERE with
  // `error` / `error_description` and no code at all, so this has to be checked
  // before looking for one.
  const reported = searchParams.get('error_description') ?? searchParams.get('error')
  if (reported) return fail(reported)

  const code = searchParams.get('code')
  if (!code) return fail('missing_code')

  const supabase = await createClient()
  const { error } = await supabase.auth.exchangeCodeForSession(code)
  if (error) return fail(error.message)

  return redirigir(safeNext(searchParams.get('next')))
}
