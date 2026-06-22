#!/usr/bin/env python3
"""Poller calendrier : ferroxide (Proton CalDAV) -> L5 /webhooks/calendrier.

Tourne DANS le LXC proton-caldav (ferroxide bind 127.0.0.1:8081). Liste les
objets de chaque calendrier par PROPFIND, récupère chaque événement
INDIVIDUELLEMENT (GET), normalise et upsert dans L5 par UID via le webhook.

Important : on ne fait PAS de REPORT global. ferroxide renvoie un 500 sur tout
le lot si UN événement a un auteur sans email (« could not get public keys for
author : Email est nécessaire »). En récupérant event par event, un objet cassé
est simplement ignoré sans casser la synchro.

Config via variables d'environnement (cf. /etc/cal-poller.env) :
  CALDAV_URL, CALDAV_USER, CALDAV_PASS
  L5_WEBHOOK_URL, N8N_WEBHOOK_SECRET
  WINDOW_PAST_DAYS (def 7), WINDOW_FUTURE_DAYS (def 90)
"""
import os
import sys
import datetime as dt

import caldav
import requests
from icalendar import Calendar

UTC = dt.timezone.utc


def env(name, default=None, required=False):
    v = os.environ.get(name, default)
    if required and not v:
        sys.exit(f"[cal-poller] variable {name} manquante")
    return v


def iso(x):
    """ISO 8601 ; les dates 'journée entière' -> minuit."""
    if x is None:
        return None
    if isinstance(x, dt.datetime):
        return x.isoformat()
    return dt.datetime(x.year, x.month, x.day).isoformat()


def aware(x):
    """Datetime tz-aware pour le filtrage par fenêtre (dates -> minuit UTC)."""
    if isinstance(x, dt.datetime):
        return x if x.tzinfo else x.replace(tzinfo=UTC)
    return dt.datetime(x.year, x.month, x.day, tzinfo=UTC)


def main():
    url = env("CALDAV_URL", "http://127.0.0.1:8081/")
    user = env("CALDAV_USER", required=True)
    pw = env("CALDAV_PASS", required=True)
    hook = env("L5_WEBHOOK_URL", required=True)
    secret = env("N8N_WEBHOOK_SECRET", required=True)
    past = int(env("WINDOW_PAST_DAYS", "7"))
    future = int(env("WINDOW_FUTURE_DAYS", "90"))

    now = dt.datetime.now(UTC)
    win_start, win_end = now - dt.timedelta(days=past), now + dt.timedelta(days=future)

    client = caldav.DAVClient(url=url, username=user, password=pw)
    principal = client.principal()

    out, seen = [], set()
    skipped = 0
    for cal in principal.calendars():
        # PROPFIND Depth:1 -> liste des hrefs d'objets (pas de sérialisation des events)
        try:
            children = cal.children()
        except Exception as e:
            print(f"[cal-poller] liste du calendrier échouée: {e}", file=sys.stderr)
            continue
        for child in children:
            href = child[0] if isinstance(child, (tuple, list)) else child
            obj = caldav.CalendarObjectResource(client=client, url=href, parent=cal)
            try:
                obj.load()          # GET d'UN seul event : isole les 500 ferroxide
                raw = obj.data
            except Exception:
                skipped += 1
                continue
            try:
                comp = Calendar.from_ical(raw)
            except Exception:
                skipped += 1
                continue
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

    r = requests.post(hook, json={"events": out},
                      headers={"Authorization": "Bearer " + secret}, timeout=30)
    print(f"[cal-poller] {len(out)} événements ({skipped} ignorés) -> {r.status_code} {r.text[:200]}")
    r.raise_for_status()


if __name__ == "__main__":
    main()
