#!/usr/bin/env python3
"""Diagnostic ferroxide : liste les calendriers et signale lesquels sont
listables (OK) vs ceux qui font planter ferroxide (FAIL — event sans auteur).
Lit /etc/cal-poller.env directement. Lancer avec le python du venv :
  /opt/cal-poller/venv/bin/python /opt/cal-poller/diag.py
"""
import caldav


def load_env(path="/etc/cal-poller.env"):
    env = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            env[k] = v
    return env


def main():
    e = load_env()
    c = caldav.DAVClient(url=e["CALDAV_URL"], username=e["CALDAV_USER"], password=e["CALDAV_PASS"])
    cals = c.principal().calendars()
    print(f"{len(cals)} calendrier(s) :")
    for cal in cals:
        try:
            name = cal.get_display_name()
        except Exception:
            name = "?"
        try:
            n = len(cal.children())
            print(f"  OK   {name!r}  -> {n} objets")
        except Exception as ex:
            print(f"  FAIL {name!r}  -> {str(ex).splitlines()[0][:70]}")


if __name__ == "__main__":
    main()
