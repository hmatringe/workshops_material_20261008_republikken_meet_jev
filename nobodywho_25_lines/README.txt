Autour du post NobodyWho "Jev in 25 lines of Python" (2026-09-22)

Le post : Qwen3-0.6B en local, logits du token suivant sur A/B/C, normalises. "That's Jev."
Ce qu'il ne mesure pas : la calibration des probabilites, ni meme l'accuracy sur une vraie tache.

Ce qu'on a fait (2026-10-07 soir), voir ../benchmark/
- Le meme principe, reproduit dans benchmark/local_25_lines.py (mlx-lm sur Apple Silicon, memes poids
  Qwen3-0.6B que le billet, logits du token suivant pour A et B, softmax). Aucune cle, aucun entrainement.
- Lance sur les deux jeux audites (326 mails, 324 trajets), meme prompt que Jev et Sonnet.

Premier resultat, Qwen3-0.6B
- Mails : accuracy 54 %, F1 0,11. Trajets : accuracy 49 %. Une piece de monnaie.
- Ce n'est pas un biais de lettre : options inversees, meme decision sur 39 mails sur 40. Le modele
  repond "pas de spam" a presque tout, avec une probabilite de 0,97. ECE 0,33 sur les mails.
- Lecture pour la salle : meme interface que Jev, un nombre entre 0 et 1, mais le nombre ne veut rien
  dire. "25 lignes" donnent la forme, pas le jugement ni la calibration.
Deuxieme resultat, Qwen3-4B (meme script, --model=Qwen/Qwen3-4B)
- Mails : accuracy 82 %, F1 0,78, ECE 0,18. Trajets : accuracy 81 %, F1 0,84, ECE 0,19.
- Easy 88 %, medium 88 %, hard 68 % sur les mails : les niveaux de difficulte se voient.
- Mais 0,3 % des items entre 0,40 et 0,60 : le modele n'hesite jamais. Il a raison quatre fois sur cinq
  et il est sur de lui cinq fois sur cinq. Un ECE de 0,18, c'est 18 points d'ecart en moyenne entre la
  probabilite annoncee et la frequence observee. Une bande de revue humaine ne recevrait rien.
- Latence : 0,9 a 1,7 s par item en local, contre 70 a 500 ms annonces pour Jev, par lot.
- Lecture : la taille donne le jugement. Elle ne donne pas la calibration. C'est la question a poser a Jev,
  et seul son run repond : meme accuracy ou pas, et combien d'items dans la zone 40-60 %.

A montrer
- benchmark/results/report.md : le tableau accuracy, Brier, ECE, zone 40-60 %, latence, cout.
- benchmark/results/reliability-*.svg : les diagrammes de fiabilite, un par scorer et par jeu.
