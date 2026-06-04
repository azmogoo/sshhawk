# Exemples de rapports SSHawk

Ces fichiers ont été générés avec le jeu de test `samples/sample-auth.log` (adresses RFC 5737 / documentation uniquement).

```bash
./sshawk.sh --file samples/sample-auth.log --no-geo
./sshawk.sh --file samples/sample-auth.log --no-geo --format text --output reports/examples/sshawk_sample_report.txt
```

| Fichier | Format |
|---------|--------|
| `sshawk_sample_report.md` | Markdown (sortie par défaut) |
| `sshawk_sample_report.txt` | Texte (`--format text`) |

Les rapports horodatés produits en local dans `reports/` restent ignorés par Git.
