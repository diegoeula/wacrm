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
 * Every failure lands on /reset-password with an `error`, instead of a bare 404
 * or a silent bounce to /login. That page has no session in this case and says
 * so — "the link expired, ask for another one" — which is the only thing the
 * person can act on. A redirect to /login would show a password box to someone
 * who is there precisely because they do not have a password.
 */
function fail(request: NextRequest, reason: string) {
  const url = request.nextUrl.clone()
  url.pathname = '/reset-password'
  url.search = `?error=${encodeURIComponent(reason)}`
  return NextResponse.redirect(url)
}

export async function GET(request: NextRequest) {
  const { searchParams } = request.nextUrl

  // GoTrue reports an expired or already-used link by redirecting HERE with
  // `error` / `error_description` and no code at all, so this has to be checked
  // before looking for one.
  const reported = searchParams.get('error_description') ?? searchParams.get('error')
  if (reported) return fail(request, reported)

  const code = searchParams.get('code')
  if (!code) return fail(request, 'missing_code')

  const supabase = await createClient()
  const { error } = await supabase.auth.exchangeCodeForSession(code)
  if (error) return fail(request, error.message)

  // `request.nextUrl.clone()` and not `new URL(request.url)`: behind the reverse
  // proxy the raw request URL carries the *internal* host and port, and a
  // redirect built from it sends the browser somewhere it cannot reach. This is
  // the same idiom `src/middleware.ts` already uses for its own redirects.
  const url = request.nextUrl.clone()
  url.pathname = safeNext(searchParams.get('next'))
  url.search = ''
  return NextResponse.redirect(url)
}
