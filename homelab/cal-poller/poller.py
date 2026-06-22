#!/usr/bin/env python3
"""Poller calendrier : ferroxide (Proton CalDAV) -> L5 /webhooks/calendrier.

Tourne DANS le LXC proton-caldav (ferroxide bind 127.0.0.1:8081). Lit les
événements d'une fenêtre glissante, les normalise, et les upsert dans L5 par
UID via le webhook d'ingestion (secret n8n).

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


def env(name, default=None, required=False):
    v = os.environ.get(name, default)
    if required and not v:
        sys.exit(f"[cal-poller] variable {name} manquante")
    return v


def iso(x):
    """ISO 8601 ; les dates 'journée entière' -> minuit local."""
    if x is None:
        return None
    if isinstance(x, dt.datetime):
        return x.isoformat()
    return dt.datetime(x.year, x.month, x.day).isoformat()


def main():
    url = env("CALDAV_URL", "http://127.0.0.1:8081/")
    user = env("CALDAV_USER", required=True)
    pw = env("CALDAV_PASS", required=True)
    hook = env("L5_WEBHOOK_URL", required=True)
    secret = env("N8N_WEBHOOK_SECRET", required=True)
    past = int(env("WINDOW_PAST_DAYS", "7"))
    future = int(env("WINDOW_FUTURE_DAYS", "90"))

    now = dt.datetime.now(dt.timezone.utc)
    start, end = now - dt.timedelta(days=past), now + dt.timedelta(days=future)

    client = caldav.DAVClient(url=url, username=user, password=pw)
    principal = client.principal()

    out, seen = [], set()
    for cal in principal.calendars():
        try:
            results = cal.search(start=start, end=end, event=True, expand=True)
        except Exception:
            results = cal.events()  # fallback : pas d'expansion des récurrences
        for ev in results:
            for sub in Calendar.from_ical(ev.data).walk("VEVENT"):
                base = str(sub.get("uid") or "").strip()
                if not base or not sub.get("dtstart"):
                    continue
                dts = sub.get("dtstart").dt
                dte = sub.get("dtend").dt if sub.get("dtend") else None
                rid = sub.get("recurrence-id")
                # récurrences : UID composite (UID#date) pour ne pas s'écraser entre elles
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
    print(f"[cal-poller] {len(out)} événements -> {r.status_code} {r.text[:200]}")
    r.raise_for_status()


if __name__ == "__main__":
    main()
