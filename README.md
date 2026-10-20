# AikoRelink

Plus jamais de « média hors ligne » dans DaVinci Resolve. Tu as déplacé des rushs, renommé un disque, rebranché un SSD sous un autre nom : AikoRelink fouille tes disques, retrouve chaque fichier (même renommé) et répare le projet ouvert dans DaVinci.

## Comment il reconnaît un fichier

Même nom (ou presque : « drone_04 » = « drone 04 »), mêmes dossiers en fin de chemin, même durée (quand macOS sait la lire), même date de création. Si la plupart des médias d'un ancien dossier sont dans un même nouveau dossier, les autres y sont cherchés en priorité. Chaque média reçoit une note : Sûr, Probable ou À vérifier.

## Prérequis

- DaVinci Resolve **Studio**, ouvert avec le projet.
- Dans DaVinci : Préférences → Système → Général → « Script externe » : **Local**.

## Installation (Mac)

Double-clic sur `macos/Installer AikoRelink.command`.
