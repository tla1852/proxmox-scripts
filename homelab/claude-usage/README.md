# claude-usage — compteurs du compte Claude dans L5

Lit l'usage **Claude Code** (`~/.claude/projects/**/*.jsonl`) via
[`ccusage`](https://github.com/ryoppippi/ccusage) et le pousse dans L5
(`POST /webhooks/claude-usage`). L5 affiche : coût-équivalent API €/jour & mois,
tokens, et l'état de la **fenêtre de débit de 5h** (limite Claude Code).

> Tu es sur un **abonnement** (pas d'`ANTHROPIC_API_KEY`) : les compteurs
> viennent des logs locaux, pas de l'API console. Le coût affiché est le coût
> API *équivalent* (ce que les sessions auraient coûté en pay-as-you-go).

## Où ça tourne

Sur l'hôte qui détient `~/.claude` (= l'hôte **Proxmox**), pas dans le LXC L5.
Service systemd `oneshot` + timer (toutes les 15 min), sous l'utilisateur
propriétaire des logs.

## Install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/tla1852/proxmox-scripts/main/homelab/claude-usage/install.sh)
```

Demande : utilisateur Claude Code, URL L5, secret webhook (= `N8N_WEBHOOK_SECRET`
de L5). Prérequis L5 : variable d'env `N8N_WEBHOOK_SECRET` définie (sinon le
webhook accepte sans secret en dev).

## Vérifier

```bash
sudo systemctl start claude-usage.service
journalctl -u claude-usage.service -n 20 --no-pager   # -> "L5 200: {...}"
```

Puis L5 → onglet **Compte Claude**.

## Homarr (tuile résumé)

Ajouter un widget **iframe** pointant sur la carte compacte L5 :

```
http://192.168.1.43:3000/embed/claude
```

Route publique (LAN, sans auth) : n'expose que les compteurs d'usage.
Pour un simple lien, une tuile *app* vers `http://192.168.1.43:3000/app/claude`.

## Fichiers

| Fichier | Rôle |
|---|---|
| `poller.sh` | source nvm, lance `ccusage daily/blocks --json`, appelle `post.py` |
| `post.py` | mappe la sortie ccusage → payload L5 et POST |
| `install.sh` | dépose les fichiers, installe ccusage, écrit l'env + le timer systemd |
