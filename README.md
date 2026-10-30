# Digistban pour iPhone

L’app affiche https://digistban.com/help dans une vue web native : chaque mise à jour du
site arrive dans l’app sans réinstaller d’IPA. Ce dépôt ne contient que la coquille iOS ;
le site vit dans le dépôt principal (dossier `frontend/`, pont : `frontend/src/lib/native.ts`).

Ce que la partie native ajoute :

- écran de lancement identique à celui du site, puis fondu vers l’app ;
- écran « Pas de connexion » qui réessaie tout seul quand le réseau revient ;
- glissement depuis le bord gauche pour revenir en arrière ;
- téléchargements ouverts dans Quick Look (enregistrer dans Fichiers ou Photos) ;
- micro et caméra autorisés une fois pour toutes (appels, messages vocaux) ;
- vibrations, pastille du nombre de messages non lus sur l’icône, écran allumé pendant un appel ;
- notifications locales des nouveaux messages (voir les limites ci-dessous) ;
- liens `digistban://…` (par exemple `digistban://d/abcd` ouvre un lien de partage).

## Fabriquer l’IPA

Chaque push sur `main` lance `.github/workflows/build.yml` sur un Mac de GitHub :
le projet Xcode est généré par XcodeGen (`project.yml`), compilé sans signature, puis
`Digistban.ipa` est publiée dans **Releases**. Pour relancer à la main : onglet **Actions** >
**Build IPA** > **Run workflow**.

La version affichée se règle dans `project.yml` (`MARKETING_VERSION`) ; le numéro de build
est celui du workflow.

## Installer sur l’iPhone (Sideloadly, Windows)

1. Installer **iTunes** et **iCloud** depuis le site d’Apple (pas la version Microsoft Store),
   puis **Sideloadly** (sideloadly.io).
2. Brancher l’iPhone en USB, le déverrouiller et accepter « Faire confiance à cet ordinateur ».
3. Télécharger `Digistban.ipa` depuis la dernière release, la glisser dans Sideloadly,
   saisir votre Apple ID **dans Sideloadly** et cliquer sur **Start**.
4. Sur l’iPhone : Réglages > Confidentialité et sécurité > **Mode développeur** : activer,
   redémarrer, confirmer.
5. Réglages > Général > **VPN et gestion de l’appareil** : faire confiance à votre Apple ID.
6. Ouvrir Digistban, se connecter, puis autoriser les notifications (carte proposée par
   l’app, ou Profil > Notifications). Vérifier que Réglages > Général > **Actualisation en
   arrière-plan** est activé pour Digistban.

Avec un Apple ID gratuit, Apple limite la signature à **7 jours** : il faut refaire l’étape 3
avant l’échéance (la session et les réglages sont conservés). Sideloadly peut le faire
automatiquement si le PC reste allumé sur le même Wi-Fi que l’iPhone (option *Auto refresh*).

## Limites avec un Apple ID gratuit

Apple réserve les notifications push aux comptes développeur payants (99 €/an). L’app s’en
passe ainsi :

- **app ouverte** : messages et appels en direct, comme sur le site ;
- **app en arrière-plan depuis peu** : notification immédiate tant qu’iOS la laisse tourner ;
- **app fermée** : iOS réveille l’app de temps en temps (Background App Refresh) pour vérifier
  les messages non lus. C’est iOS qui choisit le moment : souvent toutes les 15 à 60 minutes
  pour une app utilisée chaque jour, moins souvent sur batterie faible ou en mode économie
  d’énergie. Les appels ne sonnent pas quand l’app est fermée.

Avec un compte payant, on peut ajouter de vraies notifications push (et des appels qui sonnent
comme un appel téléphonique) : il faudra alors une clé APNs côté serveur et une signature avec
ce compte.
