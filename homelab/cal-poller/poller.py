#!/usr/bin/env python3
"""Poller calendrier -> L5 /webhooks/calendrier.

Deux modes (le mode ICS prime s'il est configuré) :

  • Mode ICS (recommandé) : GET d'une/plusieurs URL .ics partagées par Proton
    (Paramètres > Mes calendriers > Partager > lien). Proton sert son propre
    export -> contourne le bug ferroxide (« could not get public keys for
    author »). Variable CAL_ICS_URLS (séparées par des virgules).

  • Mode CalDAV : lit ferroxide (127.0.0.1:8081). Inutilisable si un event a un
    auteur sans email (ferroxide 500 même pour lister la collection).

Tourne dans le LXC proton-caldav, en timer systemd.

Config (/etc/cal-poller.env) :
  CAL_ICS_URLS                      -> active le mode ICS
  CALDAV_URL, CALDAV_USER, CALDAV_PASS   -> mode CalDAV (fallback)
  L5_WEBHOOK_URL, N8N_WEBHOOK_SECRET
  WINDOW_PAST_DAYS (def 7), WINDOW_FUTURE_DAYS (def 90)
"""
import os
import sys
import datetime as dt

import requests
from icalendar import Calendar

UTC = dt.timezone.utc


def env(name, default=None, required=False):
    v = os.environ.get(name, default)
    if required and not v:
        sys.exit(f"[cal-poller] variable {name} manquante")
    return v


def iso(x):
    if x is None:
        return None
    if isinstance(x, dt.datetime):
        return x.isoformat()
    return dt.datetime(x.year, x.month, x.day).isoformat()


def aware(x):
    if isinstance(x, dt.datetime):
        return x if x.tzinfo else x.replace(tzinfo=UTC)
    return dt.datetime(x.year, x.month, x.day, tzinfo=UTC)


def harvest(comp, out, seen, win_start, win_end):
    """Extrait les VEVENT d'un VCALENDAR dans la fenêtre, dédupliqués par UID."""
    for sub in comp.walk("VEVENT"):
        base = str(sub.get("uid") or "").strip()
        if not base or not sub.get("dtstart"):
            continue
        dts = sub.get("dtstart").dt
        if not (win_start <= aware(dts) <= win_end):
            continue
        dte = sub.get("dtend").dt if sub.get("dtend") else None
        rid = sub.get("recurrence-id")
        uid = base if rid is None else f"{base}#{iso(rid.dt)[:10]}"
        if uid in seen:
            continue
        seen.add(uid)
        out.append({
            "uid": uid,
            "titre": str(sub.get("summary") or "") or None,
            "debut": iso(dts),
            "fin": iso(dte),
            "lieu": str(sub.get("location") or "") or None,
            "description": str(sub.get("description") or "") or None,
        })


def from_ics(urls, out, seen, win_start, win_end):
    for u in [x.strip() for x in urls.split(",") if x.strip()]:
        r = requests.get(u, timeout=30)
        r.raise_for_status()
        harvest(Calendar.from_ical(r.content), out, seen, win_start, win_end)


def from_caldav(out, seen, win_start, win_end):
    import caldav
    client = caldav.DAVClient(
        url=env("CALDAV_URL", "http://127.0.0.1:8081/"),
        username=env("CALDAV_USER", required=True),
        password=env("CALDAV_PASS", required=True),
    )
    for cal in client.principal().calendars():
        try:
            children = cal.children()
        except Exception as e:
            print(f"[cal-poller] liste du calendrier échouée: {e}", file=sys.stderr)
            continue
        for child in children:
            href = child[0] if isinstance(child, (tuple, list)) else child
            obj = caldav.CalendarObjectResource(client=client, url=href, parent=cal)
            try:
                obj.load()
            except Exception:
                continue
            try:
                harvest(Calendar.from_ical(obj.data), out, seen, win_start, win_end)
            except Exception:
                continue


def post_events(hook, secret, events, source_id=None, frm=None, to=None):
    payload = {"events": events}
    if source_id:
        payload.update(source_id=source_id, **({"from": frm, "to": to} if frm and to else {}))
    r = requests.post(hook, json=payload,
                      headers={"Authorization": "Bearer " + secret}, timeout=30)
    r.raise_for_status()
    return r


def l5_sources(hook, secret):
    """Liste des calendriers gérés dans L5 (source de vérité)."""
    base = hook.rsplit("/webhooks/", 1)[0]
    r = requests.get(base + "/webhooks/cal-sources",
                     headers={"Authorization": "Bearer " + secret}, timeout=20)
    r.raise_for_status()
    return r.json() or []


def main():
    hook = env("L5_WEBHOOK_URL", required=True)
    secret = env("N8N_WEBHOOK_SECRET", required=True)
    past = int(env("WINDOW_PAST_DAYS", "7"))
    future = int(env("WINDOW_FUTURE_DAYS", "90"))
    now = dt.datetime.now(UTC)
    win_start, win_end = now - dt.timedelta(days=past), now + dt.timedelta(days=future)
    frm, to = win_start.isoformat(), win_end.isoformat()

    # 1) Calendriers gérés dans L5 (chacun = un lien ICS, posté avec son source_id).
    sources = []
    try:
        sources = l5_sources(hook, secret)
    except Exception as e:
        print(f"[cal-poller] liste des sources L5 indisponible: {e}", file=sys.stderr)

    if sources:
        total = 0
        for s in sources:
            out, seen = [], set()
            try:
                from_ics(s["url"], out, seen, win_start, win_end)
            except Exception as e:
                print(f"[cal-poller] source {s.get('nom')!r} ICS échec: {e}", file=sys.stderr)
                continue
            post_events(hook, secret, out, source_id=s["id"], frm=frm, to=to)
            total += len(out)
            print(f"[cal-poller] {s.get('nom')!r}: {len(out)} événements")
        print(f"[cal-poller] mode=l5-sources {len(sources)} calendrier(s), {total} événements")
        return

    # 2) Fallback : variable CAL_ICS_URLS (bootstrap, sans source_id).
    out, seen = [], set()
    ics_urls = env("CAL_ICS_URLS")
    mode = "ics-env" if ics_urls else "caldav"
    if ics_urls:
        from_ics(ics_urls, out, seen, win_start, win_end)
    else:
        from_caldav(out, seen, win_start, win_end)
    r = post_events(hook, secret, out)
    print(f"[cal-poller] mode={mode} {len(out)} événements -> {r.status_code} {r.text[:200]}")


if __name__ == "__main__":
    main()
