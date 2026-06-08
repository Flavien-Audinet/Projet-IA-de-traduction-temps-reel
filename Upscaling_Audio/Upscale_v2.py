import soundcard as sc
import numpy as np
import tensorflow as tf
from waveunet import WaveUNet  # Assurez-vous que Wave-U-Net est dans votre PYTHONPATH
import librosa

# Paramètres audio
RATE = 48000  # Fréquence d'échantillonnage (dépend du périphérique)
CHUNK = 1024  # Taille du buffer
CHANNELS = 1  # Mono

# Obtenir le haut-parleur par défaut (périphérique de lecture)
speaker = sc.default_speaker()
# Obtenir le microphone ou le périphérique de capture audio par défaut (par exemple, le son du système)
mic = sc.get_microphone(sc.default_microphone().name, include_loopback=True)

# Charger un modèle pré-entraîné Wave-U-Net
model = WaveUNet()
model.load_weights("path_to_trained_model_weights.h5")  # Chemin vers les poids du modèle

# Fonction pour traiter un segment audio avec Wave-U-Net
def process_audio(audio_data):
    # Reshape en format attendu par le modèle Wave-U-Net
    audio_data = np.reshape(audio_data, (1, len(audio_data), CHANNELS))

    # Appliquer le modèle pour améliorer la qualité du son
    processed_audio = model.predict(audio_data)

    # Reshape pour la lecture en temps réel
    processed_audio = np.squeeze(processed_audio)

    return processed_audio

print("Traitement audio en temps réel démarré...")

# Démarrer la capture et le traitement en temps réel
with mic.recorder(samplerate=RATE, channels=CHANNELS) as rec, \
     speaker.player(samplerate=RATE, channels=CHANNELS) as player:
    
    while True:
        # Capturer l'audio interne du système
        audio_data = rec.record(numframes=CHUNK)
        
        # Appliquer le traitement avec Wave-U-Net
        processed_audio = process_audio(audio_data)
        
        # Rejouer le son traité via les haut-parleurs
        player.play(processed_audio)
