# 🌍 IA de Traduction Temps Réel avec Deepfake Audio
**Reconstruction dynamique des textes & clonage vocal**

[![Python](https://img.shields.io/badge/Python-3.8%2B-blue)](https://www.python.org/)
[![Licence](https://img.shields.io/badge/Licence-Proprio-red)](https://github.com/Flavien-Audinet/Projet-IA-de-traduction-temps-reel/blob/main/LICENSE.md)
[![Statut](https://img.shields.io/badge/Statut-En%20Développement-orange)](https://github.com/Flavien-Audinet/Projet-IA-de-traduction-temps-reel)
[![MyTranslate v2](https://img.shields.io/badge/MyTranslate-v2.0.0-2ea44f)](MyTranslate_v2/README.md)

---

## 🆕 **MyTranslate v2 (2026) — la version fonctionnelle**

> Le projet a été réécrit de zéro en **app macOS native** : 👉 **[MyTranslate_v2/](MyTranslate_v2/README.md)**
> App prête à lancer dans la [release MyTranslate v2.0.0](https://github.com/Flavien-Audinet/Projet-IA-de-traduction-temps-reel/releases/tag/MyTranslate-v2.0.0).

| Module | Ce qu'il fait | État |
|---|---|---|
| 🖥️ **Texte à l'écran** | traduit le texte de n'importe quelle app par-dessus l'original (police, taille, couleurs conservées), suit le défilement en direct | ✅ stable |
| 🌐 **Pages web** | extension Firefox : traduction sur place, automatique pour les pages en anglais | ✅ stable |
| 🎧 **Écouter traduit** | doublage des vidéos en français avec la voix imitée de la personne qui parle, fond sonore conservé | 🧪 expérimental |

100 % local (Vision, ScreenCaptureKit, MLX, Opus-MT, Chatterbox) · macOS 15+ · Apple Silicon · anglais ↔ français.

Les dossiers ci-dessous sont les **prototypes Python de 2024** (OCR, noyaux de traduction, séparation audio), conservés comme historique du projet.

---

## 📌 **À propos**
Une solution innovante pour la **traduction instantanée** avec :
✅ **Clonage vocal** (voix d’utilisateurs, vidéos, audios, jeux, films)
✅ **Restitution naturelle** dans la langue cible (accents, expressions)
✅ **Reconstruction dynamique** des textes (adaptation du contenu, police, couleurs, mise en forme selon le support et l’angle de vue)

**Contexte** :
Idée originale en **2015**, développement actif depuis **2024**.

---

## 🛠 **Fonctionnalités (prototypes 2024)**
   Module               | Description                                                                 |
 |----------------------|-----------------------------------------------------------------------------|
 | `Noyaux_de_Traduction_Textuel` | Moteur de traduction temps réel                                           |
 | `OCR`                | Reconnaissance optique de caractères pour extraire du texte               |
 | `Prototype`          | Démonstration fonctionnelle (version obsolète partagée)                  |
 | `Upscaling_Audio`    | Amélioration de la qualité audio pour le deepfake                          |
 | `training`           | Scripts d’entraînement des modèles (ex: `AI_training.py`)                 |

---

## ⚠️ **Avertissement Légal**
> ❌ **Toute copie, reproduction ou utilisation non autorisée est strictement interdite.**
> Les prototypes 2024 à la racine sont une **version obsolète et non fonctionnelle** ; la version actuelle est [MyTranslate v2](MyTranslate_v2/README.md).
> **Respectez la propriété intellectuelle** – Contactez-moi pour toute collaboration.
> Conditions complètes : [LICENSE.md](LICENSE.md) (utilisation autorisée ; modification, revente et redistribution interdites).

---

## 📦 **Prérequis**
- Python 3.8+
- GPU (recommandé pour l’upscaling audio)
- Bibliothèques : `torch`, `transformers`, `librosa`, etc. (voir `requirements.txt`)

---
## 🚀 **Installation**
```bash
git clone https://github.com/Flavien-Audinet/Projet-IA-de-traduction-temps-reel.git
cd Projet-IA-de-traduction-temps-reel
pip install -r requirements.txt
